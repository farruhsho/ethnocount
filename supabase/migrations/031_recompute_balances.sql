-- ============================================================
-- 031: Recompute account_balances from ledger_entries (P2 fix)
-- ============================================================
-- Симптом: бухгалтер видит «Доступно: −10 000 000» на счёте, который
-- был пополнён (показывается в плюсе). То есть кэш в `account_balances`
-- разошёлся с источником истины `ledger_entries` (credit/debit-движения).
--
-- Возможные причины расхождения, накопившиеся за историю проекта:
--   • миграции 005/012/014/020/022/028 несколько раз меняли логику
--     debit/credit при перевод/выдаче/доставке. Если в проде остались
--     переводы старого статуса, частичные изменения могли оставить
--     кэш расхождённым.
--   • ручная правка `account_balances` или `ledger_entries` без второй
--     половины.
--   • откат транзакции на клиенте без серверной RPC.
--
-- Что делает эта миграция:
--   1) `private.account_balance_audit(p_account_id)` — диагностическая
--      функция: возвращает (cached, computed, diff) для одного счёта.
--   2) `private.account_balances_audit_all()` — то же самое по всем
--      счетам, можно прогнать SELECT * чтобы увидеть все расхождения.
--   3) `private.recompute_account_balances(p_account_id uuid DEFAULT NULL)`
--      — пересчитывает баланс из ledger_entries (SUM credit - SUM debit).
--      Если p_account_id = NULL — пересчитывает все счета.
--   4) Публичные RPC-обёртки `admin_*` с проверкой роли creator.
--
-- Запуск (как creator):
--   SELECT * FROM private.account_balances_audit_all() WHERE diff <> 0;
--   SELECT public.admin_recompute_balances();  -- все счета
--   -- или для одного:
--   SELECT public.admin_recompute_balances('<account-uuid>');
--
-- Идемпотентно — можно применять повторно.
-- ============================================================

-- ─── 1. Аудит одного счёта ────────────────────────────────────
CREATE OR REPLACE FUNCTION private.account_balance_audit(p_account_id uuid)
RETURNS TABLE (
  account_id uuid,
  cached double precision,
  computed double precision,
  diff double precision,
  ledger_rows bigint
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    ab.account_id,
    ab.balance AS cached,
    COALESCE((
      SELECT SUM(CASE WHEN le.type = 'credit' THEN le.amount
                      WHEN le.type = 'debit'  THEN -le.amount
                      ELSE 0 END)
      FROM ledger_entries le
      WHERE le.account_id = ab.account_id
    ), 0) AS computed,
    ab.balance - COALESCE((
      SELECT SUM(CASE WHEN le.type = 'credit' THEN le.amount
                      WHEN le.type = 'debit'  THEN -le.amount
                      ELSE 0 END)
      FROM ledger_entries le
      WHERE le.account_id = ab.account_id
    ), 0) AS diff,
    (SELECT COUNT(*) FROM ledger_entries le2 WHERE le2.account_id = ab.account_id) AS ledger_rows
  FROM account_balances ab
  WHERE ab.account_id = p_account_id;
$$;

-- ─── 2. Аудит всех счетов сразу ──────────────────────────────
CREATE OR REPLACE FUNCTION private.account_balances_audit_all()
RETURNS TABLE (
  account_id uuid,
  branch_id uuid,
  account_name text,
  currency text,
  cached double precision,
  computed double precision,
  diff double precision,
  ledger_rows bigint
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH sums AS (
    SELECT
      le.account_id,
      SUM(CASE WHEN le.type = 'credit' THEN le.amount
               WHEN le.type = 'debit'  THEN -le.amount
               ELSE 0 END) AS computed,
      COUNT(*) AS ledger_rows
    FROM ledger_entries le
    GROUP BY le.account_id
  )
  SELECT
    ab.account_id,
    ab.branch_id,
    ba.name AS account_name,
    ab.currency,
    ab.balance AS cached,
    COALESCE(s.computed, 0) AS computed,
    ab.balance - COALESCE(s.computed, 0) AS diff,
    COALESCE(s.ledger_rows, 0) AS ledger_rows
  FROM account_balances ab
  LEFT JOIN sums s ON s.account_id = ab.account_id
  LEFT JOIN branch_accounts ba ON ba.id = ab.account_id
  ORDER BY ABS(ab.balance - COALESCE(s.computed, 0)) DESC;
$$;

-- ─── 3. Пересчёт балансов из ledger_entries ──────────────────
-- Безопасно: блокирует обновляемые строки на время операции.
-- Если строки нет — создаёт.
CREATE OR REPLACE FUNCTION private.recompute_account_balances(
  p_account_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_updated int := 0;
  v_account record;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User must be authenticated';
  END IF;

  IF p_account_id IS NOT NULL THEN
    -- Точечный пересчёт одного счёта.
    PERFORM 1 FROM branch_accounts WHERE id = p_account_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Account not found: %', p_account_id;
    END IF;

    -- Защита от потери легаси-балансов: если у счёта нет вообще записей
    -- в ledger_entries, отказываем — иначе обнулим баланс. Creator должен
    -- сначала зафиксировать openingBalance через adjust_balance.
    PERFORM 1 FROM ledger_entries WHERE account_id = p_account_id LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION
        'Cannot recompute: account % has zero ledger entries. Set opening balance via adjust_balance first.',
        p_account_id;
    END IF;

    -- Лочим строку (или создаём, если её нет).
    PERFORM 1 FROM account_balances WHERE account_id = p_account_id FOR UPDATE;

    WITH s AS (
      SELECT
        COALESCE(SUM(CASE WHEN type = 'credit' THEN amount
                          WHEN type = 'debit'  THEN -amount
                          ELSE 0 END), 0) AS computed
      FROM ledger_entries
      WHERE account_id = p_account_id
    )
    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    SELECT
      p_account_id,
      ba.branch_id,
      s.computed,
      ba.currency,
      now()
    FROM branch_accounts ba, s
    WHERE ba.id = p_account_id
    ON CONFLICT (account_id) DO UPDATE
      SET balance = EXCLUDED.balance,
          updated_at = now();
    v_updated := 1;
  ELSE
    -- Полный пересчёт всех счетов.
    --
    -- ВАЖНО: пропускаем счета, у которых нет вообще записей в ledger_entries.
    -- Это легаси-аккаунты, чей кэшированный balance мог быть выставлен
    -- напрямую без ledger-проводки. Пересчёт обнулил бы их — это потеря
    -- данных. Такие счета должен сначала перевести в ledger creator
    -- (через openingBalance adjustment), а потом запустить recompute.
    FOR v_account IN
      SELECT ba.id, ba.branch_id, ba.currency
      FROM branch_accounts ba
      WHERE EXISTS (
        SELECT 1 FROM ledger_entries le WHERE le.account_id = ba.id LIMIT 1
      )
    LOOP
      PERFORM 1 FROM account_balances WHERE account_id = v_account.id FOR UPDATE;
      WITH s AS (
        SELECT
          COALESCE(SUM(CASE WHEN type = 'credit' THEN amount
                            WHEN type = 'debit'  THEN -amount
                            ELSE 0 END), 0) AS computed
        FROM ledger_entries
        WHERE account_id = v_account.id
      )
      INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
      SELECT v_account.id, v_account.branch_id, s.computed, v_account.currency, now()
      FROM s
      ON CONFLICT (account_id) DO UPDATE
        SET balance = EXCLUDED.balance,
            updated_at = now();
      v_updated := v_updated + 1;
    END LOOP;
  END IF;

  RETURN jsonb_build_object('success', true, 'updated', v_updated);
END;
$$;

-- ─── 4. Публичные обёртки (только creator может вызывать) ────
CREATE OR REPLACE FUNCTION public.admin_audit_balances()
RETURNS TABLE (
  account_id uuid,
  branch_id uuid,
  account_name text,
  currency text,
  cached double precision,
  computed double precision,
  diff double precision,
  ledger_rows bigint
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT role::text INTO v_role FROM public.users WHERE id = auth.uid();
  IF v_role IS NULL OR v_role <> 'creator' THEN
    RAISE EXCEPTION 'Only creator can audit balances';
  END IF;
  RETURN QUERY SELECT * FROM private.account_balances_audit_all();
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_recompute_balances(
  p_account_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT role::text INTO v_role FROM public.users WHERE id = auth.uid();
  IF v_role IS NULL OR v_role <> 'creator' THEN
    RAISE EXCEPTION 'Only creator can recompute balances';
  END IF;
  RETURN private.recompute_account_balances(p_account_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_audit_balances() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_recompute_balances(uuid) TO authenticated;
