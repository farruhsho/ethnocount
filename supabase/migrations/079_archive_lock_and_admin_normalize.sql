-- ============================================================
-- 079: гигиена форензик-аудита — гонка архива, мусорные нули
--      сальдо и нормализация легаси-роли 'admin' в RLS
-- ============================================================
-- Три низко-критичных пункта форензик-аудита (06.2026):
--
--   (#23) Гонка archive/deposit в admin_archive_client (021).
--         Функция проверяет нулевой баланс клиента БЕЗ блокировки
--         строки client_balances. Параллельный deposit_client
--         (001, берёт `SELECT balances ... FOR UPDATE` по той же
--         строке) может проскользнуть между проверкой нуля и
--         UPDATE clients.is_active=false — клиент архивируется с
--         только что зачисленным ненулевым балансом.
--         ЧИНИМ: перед проверкой нуля берём row-lock
--         `SELECT ... FROM client_balances WHERE client_id = ...
--         FOR UPDATE`. Параллельный депозит теперь блокируется до
--         коммита архива; после коммита он перечитает is_active и
--         (deposit_client проверяет is_active) получит отказ.
--         Если баланс ненулевой — RAISE как и раньше. Сигнатура
--         НЕ меняется → CREATE OR REPLACE, тело воспроизведено
--         дословно из 021, изменён ТОЛЬКО локинг.
--
--   (#25) Накопление мусорных нулевых валютных ключей в
--         counterparties.saldo_by_currency. record_counterparty_op
--         (последнее тело в 075) пишет новое сальдо через
--         `saldo_by_currency || jsonb_build_object(cur, new)` и
--         НИКОГДА не удаляет ключ, ставший нулём. Со временем jsonb
--         распухает ключами вида {"EUR":0,"RUB":0,...}, путая UI
--         (показывает позиции с нулём) и сверку.
--         ЧИНИМ минимально: добавляем helper private.prune_zero_saldo,
--         который пересобирает saldo_by_currency, оставляя только
--         ключи с round(value,2) <> 0, и ВЫЗЫВАЕМ его в конце
--         record_counterparty_op (075-тело воспроизведено дословно +
--         один PERFORM). Арифметика сальдо НЕ меняется.
--
--   (#26) Легаси-роль 'admin' рассинхронизирована в RLS. Часть
--         политик из 001/part2_rls («role IN ('creator','admin')»)
--         уже переписана на канонический private.is_creator()
--         (011 — branches/branch_accounts/account_balances/transfers/
--         ledger/purchases/...; 013 — users_select; 068 — clients/
--         client_balances/client_transactions). Но ПЯТЬ политик так
--         и остались на легаси-предикате get_user_role() IN
--         ('creator','admin'):
--             users_insert, users_update, users_delete (public.users),
--             audit_select (public.audit_logs),
--             sys_audit_select (public.system_audit_logs).
--         Роль 'admin' НЕ провижинится НИ ОДНИМ путём UI:
--           • триггер регистрации 008 выдаёт только 'creator'
--             (первый юзер) или 'accountant';
--           • private.admin_set_user_role (последнее тело — 013:241)
--             ОТКЛОНЯЕТ всё, кроме ('creator','director','accountant').
--         То есть 'admin' — мёртвый, creator-эквивалентный по смыслу
--         маркер. НОРМАЛИЗУЕМ пять политик на private.is_creator(),
--         чтобы поведение было единым со всем остальным кодом. Для
--         каждой — DROP старой политики и CREATE замены с тем же
--         именем/таблицей/командой. Точный before/after — ниже у
--         каждой политики.
--
--         Почему это НЕ ослабляет безопасность:
--           • Грант никому не расширяется: 'admin' никогда не
--             существует как живая роль, а 'creator' покрывается
--             is_creator(). Директор/бухгалтер доступа не получают.
--           • is_creator() дополнительно требует is_active=true —
--             это УЖЕСТОЧЕНИЕ (деактивированный creator теряет
--             write-доступ к users/audit), уже действующее для всех
--             прочих creator-политик (011/013/068). Ни одна реально
--             провижинимая роль не блокируется.
--           • Конституэнту-роль 'admin' в users_role_check (013:45)
--             НЕ трогаем: она безвредна (никем не выставляется) и её
--             удаление не относится к нормализации RLS.
--
-- Идемпотентно. CREATE OR REPLACE для функций (сигнатуры не
-- меняются), DROP POLICY IF EXISTS + CREATE для политик. Всё в
-- одном BEGIN/COMMIT.
-- ============================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────
-- 1. #23 — admin_archive_client: row-lock перед проверкой нуля
-- ─────────────────────────────────────────────────────────────
-- Сигнатура (uuid, boolean) НЕ меняется → CREATE OR REPLACE.
-- Тело воспроизведено ДОСЛОВНО из 021; единственное изменение —
-- добавлен `FOR UPDATE` блокирующий SELECT по client_balances
-- ПЕРЕД чтением баланса (сериализует параллельный deposit_client).
CREATE OR REPLACE FUNCTION private.admin_archive_client(
  p_client_id uuid,
  p_archive boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_balances jsonb;
  v_has_balance boolean := false;
  v_currency text;
  v_amount double precision;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Не авторизованы'; END IF;
  IF NOT private.is_creator_or_director() THEN
    RAISE EXCEPTION 'Только Creator/Director может удалять клиентов';
  END IF;

  IF p_archive THEN
    -- ── #23: блокируем строку баланса клиента ПЕРЕД проверкой нуля.
    -- deposit_client/debit_client/convert_client_currency берут
    -- `SELECT balances ... FROM client_balances ... FOR UPDATE` по
    -- этой же строке, поэтому конкурентный депозит теперь дождётся
    -- коммита архива (а затем упрётся в is_active=false). Лочим и
    -- ЧИТАЕМ баланс одним FOR UPDATE-запросом.
    SELECT balances INTO v_balances
      FROM public.client_balances WHERE client_id = p_client_id
      FOR UPDATE;

    IF v_balances IS NOT NULL THEN
      FOR v_currency, v_amount IN
        SELECT k, (val)::text::double precision
        FROM jsonb_each(v_balances) AS j(k, val)
      LOOP
        IF v_amount IS NOT NULL AND abs(v_amount) > 0.005 THEN
          v_has_balance := true;
          EXIT;
        END IF;
      END LOOP;
    END IF;

    IF v_has_balance THEN
      RAISE EXCEPTION 'Нельзя удалить клиента с ненулевым балансом. Сначала закройте кошельки.';
    END IF;
  END IF;

  UPDATE public.clients SET is_active = NOT p_archive WHERE id = p_client_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Клиент не найден'; END IF;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES (
    CASE WHEN p_archive THEN 'client.archived' ELSE 'client.restored' END,
    'client', p_client_id::text, v_uid, '{}'::jsonb);

  RETURN jsonb_build_object('success', true);
END
$$;

-- public-обёртка и GRANT из 021 остаются в силе (CREATE OR REPLACE
-- private-функции их не инвалидирует). Сигнатура не менялась.

-- ─────────────────────────────────────────────────────────────
-- 2. #25 — prune_zero_saldo + вызов в record_counterparty_op
-- ─────────────────────────────────────────────────────────────
-- Helper: пересобирает counterparties.saldo_by_currency, оставляя
-- только ключи, чьё значение в округлении до 2 знаков отлично от 0.
-- Безопасно (только удаляет «нулевые» ключи), арифметику не трогает.
CREATE OR REPLACE FUNCTION private.prune_zero_saldo(p_counterparty_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
  UPDATE counterparties
    SET saldo_by_currency = COALESCE(
      (SELECT jsonb_object_agg(k, val)
         FROM jsonb_each(saldo_by_currency) AS j(k, val)
        WHERE round((val)::text::numeric, 2) <> 0),
      '{}'::jsonb)
  WHERE id = p_counterparty_id;
$fn$;

-- record_counterparty_op: тело ВОСПРОИЗВЕДЕНО ДОСЛОВНО из 075
-- (последнее определение), добавлен ТОЛЬКО один вызов
-- `PERFORM private.prune_zero_saldo(...)` после записи сальдо.
-- Сигнатура НЕ меняется → CREATE OR REPLACE, public-обёртка и
-- GRANT из 040 остаются в силе.
CREATE OR REPLACE FUNCTION private.record_counterparty_op(
  p_counterparty_id uuid,
  p_kind text,
  p_amount double precision,
  p_currency text,
  p_description text DEFAULT NULL::text,
  p_cash_account_id uuid DEFAULT NULL::uuid,
  p_transfer_id uuid DEFAULT NULL::uuid,
  p_payout_method text DEFAULT NULL::text,
  p_exchange_rate double precision DEFAULT NULL::double precision,
  p_close_amount double precision DEFAULT NULL::double precision,
  p_close_currency text DEFAULT NULL::text,
  p_expected_rate double precision DEFAULT NULL::double precision)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  -- #12: допуск на отклонение фактического курса от ожидаемого (5%)
  c_rate_tolerance constant double precision := 0.05;
  v_uid uuid := auth.uid();
  v_cp counterparties%ROWTYPE;
  v_cash_cur text;
  v_saldo_cur text;
  v_curr_saldo double precision;
  v_saldo_delta double precision;
  v_new_saldo double precision;
  v_acc branch_accounts%ROWTYPE;
  v_cash_delta double precision;
  v_acc_balance double precision;
  v_role text;
  v_close_amount double precision;
  v_settlement_profit double precision := 0;
  v_actual_rate double precision;
  v_rate_dev double precision;
  v_limit numeric;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;

  SELECT role::text INTO v_role FROM public.users WHERE id = v_uid;

  SELECT * INTO v_cp FROM counterparties
    WHERE id = p_counterparty_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;
  IF NOT v_cp.is_active THEN RAISE EXCEPTION 'Партнёр деактивирован'; END IF;

  v_cash_cur := upper(trim(p_currency));
  IF v_cash_cur = '' THEN RAISE EXCEPTION 'Валюта обязательна'; END IF;

  v_saldo_cur := upper(COALESCE(NULLIF(trim(p_close_currency), ''), v_cash_cur));
  v_close_amount := COALESCE(p_close_amount, p_amount);
  IF v_close_amount <= 0 THEN
    RAISE EXCEPTION 'closes_amount должен быть > 0';
  END IF;

  v_saldo_delta := CASE p_kind
    WHEN 'paid_for_us'      THEN -v_close_amount
    WHEN 'we_paid_for_them' THEN  v_close_amount
    WHEN 'settle_to_us'     THEN -v_close_amount
    WHEN 'settle_from_us'   THEN  v_close_amount
    ELSE NULL
  END;
  IF v_saldo_delta IS NULL THEN
    RAISE EXCEPTION 'Неизвестный тип операции: %', p_kind;
  END IF;

  IF p_kind IN ('settle_to_us', 'settle_from_us') THEN
    IF p_cash_account_id IS NULL THEN
      RAISE EXCEPTION
        'Для расчёта (settle) обязательно укажите кеш-счёт нашего филиала';
    END IF;
    SELECT * INTO v_acc FROM branch_accounts WHERE id = p_cash_account_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Кеш-счёт не найден'; END IF;
    IF upper(v_acc.currency) <> v_cash_cur THEN
      RAISE EXCEPTION
        'Валюта расчёта (%) не совпадает с валютой выбранного счёта (%)',
        v_cash_cur, v_acc.currency;
    END IF;

    v_cash_delta := CASE p_kind
      WHEN 'settle_to_us'   THEN  p_amount
      WHEN 'settle_from_us' THEN -p_amount
    END;

    IF v_cash_delta < 0 THEN
      SELECT balance INTO v_acc_balance
        FROM account_balances WHERE account_id = p_cash_account_id FOR UPDATE;
      v_acc_balance := COALESCE(v_acc_balance, 0);
      IF v_acc_balance + v_cash_delta < 0 THEN
        RAISE EXCEPTION
          'Недостаточно средств на счёте для расчёта. Доступно: %, требуется: %',
          round(v_acc_balance::numeric, 2), round(p_amount::numeric, 2);
      END IF;
    END IF;

    INSERT INTO account_balances (account_id, branch_id, balance, currency, updated_at)
    VALUES (p_cash_account_id, v_acc.branch_id, round(v_cash_delta::numeric, 4), v_acc.currency, now())
    ON CONFLICT (account_id) DO UPDATE
      SET balance = round((account_balances.balance + v_cash_delta)::numeric, 4),
          updated_at = now();

    INSERT INTO ledger_entries
      (branch_id, account_id, type, amount, currency,
       reference_type, reference_id, description, created_by)
    VALUES (
      v_acc.branch_id, p_cash_account_id,
      CASE WHEN v_cash_delta >= 0 THEN 'credit' ELSE 'debit' END,
      p_amount, v_acc.currency,
      'adjustment',
      'cp:' || p_counterparty_id::text,
      CASE WHEN p_kind = 'settle_to_us'
           THEN 'Расчёт от партнёра ' || v_cp.name
                || CASE WHEN v_saldo_cur <> v_cash_cur
                        THEN ' (закрывает ' || v_close_amount || ' ' || v_saldo_cur || ')'
                        ELSE '' END
           ELSE 'Расчёт партнёру ' || v_cp.name
                || CASE WHEN v_saldo_cur <> v_cash_cur
                        THEN ' (закрывает ' || v_close_amount || ' ' || v_saldo_cur || ')'
                        ELSE '' END
      END,
      v_uid
    );

    IF v_saldo_cur <> v_cash_cur AND p_expected_rate IS NOT NULL
       AND p_expected_rate > 0 AND v_close_amount > 0 THEN
      -- ── #12: санити фактического курса перед расчётом прибыли ──
      -- amount и closes_amount уже проверены на > 0 выше; считаем
      -- фактический курс и отклоняем «толстый палец» по допуску.
      IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Сумма расчёта (amount) должна быть > 0';
      END IF;
      v_actual_rate := p_amount / v_close_amount;
      v_rate_dev := abs(v_actual_rate - p_expected_rate)
                    / NULLIF(p_expected_rate, 0);
      IF v_rate_dev IS NULL OR v_rate_dev > c_rate_tolerance THEN
        RAISE EXCEPTION
          'Курс расчёта вне допуска: фактический % vs ожидаемый % (отклонение %%, допуск %%). Проверьте сумму/курс.',
          round(v_actual_rate::numeric, 6),
          round(p_expected_rate::numeric, 6),
          round((COALESCE(v_rate_dev, 1) * 100)::numeric, 2),
          round((c_rate_tolerance * 100)::numeric, 2);
      END IF;

      v_settlement_profit := CASE p_kind
        WHEN 'settle_from_us' THEN (p_expected_rate - v_actual_rate) * v_close_amount
        WHEN 'settle_to_us'   THEN (v_actual_rate - p_expected_rate) * v_close_amount
        ELSE 0
      END;
    END IF;
  END IF;

  v_settlement_profit := round(COALESCE(v_settlement_profit, 0)::numeric, 4);

  v_curr_saldo := round(COALESCE(
    (v_cp.saldo_by_currency->>v_saldo_cur)::double precision, 0)::numeric, 4);
  v_new_saldo := round((v_curr_saldo + v_saldo_delta)::numeric, 4);

  -- ── F5 + #13: лимит экспозиции (АБСОЛЮТНОЕ итоговое saldo) ──
  -- Лимит ограничивает |saldo| в валюте позиции. Блокируем любую
  -- операцию, которая УВЕЛИЧИВАЕТ |saldo| сверх лимита:
  --   • рост долга (paid_for_us / we_paid_for_them);
  --   • чрезмерный расчёт (settle_*), переворачивающий знак за
  --     ноль так, что |new| > |curr| и > лимита (#13). Обычный
  --     расчёт, уменьшающий позицию, не блокируется.
  v_limit := NULLIF(v_cp.exposure_limit_by_currency->>v_saldo_cur, '')::numeric;
  IF v_limit IS NOT NULL AND v_limit > 0
     AND abs(v_new_saldo) > v_limit + 1e-6
     AND abs(v_new_saldo) > abs(v_curr_saldo) + 1e-6 THEN
    IF p_kind IN ('settle_to_us', 'settle_from_us') THEN
      RAISE EXCEPTION
        'Расчёт перевернул бы позицию по партнёру «%» в % за лимит: лимит %, позиция станет % (перерасчёт). Уменьшите сумму расчёта.',
        v_cp.name, v_saldo_cur, round(v_limit, 2), round(v_new_saldo::numeric, 2);
    ELSE
      RAISE EXCEPTION
        'Превышен лимит экспозиции по партнёру «%» в %: лимит %, позиция станет %. Сначала проведите расчёт.',
        v_cp.name, v_saldo_cur, round(v_limit, 2), round(abs(v_new_saldo)::numeric, 2);
    END IF;
  END IF;

  UPDATE counterparties
    SET saldo_by_currency = saldo_by_currency
        || jsonb_build_object(v_saldo_cur, v_new_saldo)
  WHERE id = p_counterparty_id;

  -- ── #25: удаляем ставшие нулевыми валютные ключи сальдо, чтобы
  -- saldo_by_currency не накапливал мусорные {"CUR":0}. На
  -- арифметику выше не влияет (сальдо уже записано).
  PERFORM private.prune_zero_saldo(p_counterparty_id);

  INSERT INTO counterparty_transactions
    (counterparty_id, kind, amount, currency, description, created_by,
     transfer_id, cash_account_id, payout_method, exchange_rate,
     closes_amount, closes_currency, expected_rate,
     settlement_profit, settlement_profit_currency)
  VALUES
    (p_counterparty_id, p_kind, p_amount, v_cash_cur,
     NULLIF(trim(p_description), ''), v_uid,
     p_transfer_id, p_cash_account_id,
     NULLIF(trim(p_payout_method), ''), p_exchange_rate,
     CASE WHEN v_saldo_cur <> v_cash_cur THEN v_close_amount ELSE NULL END,
     CASE WHEN v_saldo_cur <> v_cash_cur THEN v_saldo_cur ELSE NULL END,
     p_expected_rate,
     NULLIF(v_settlement_profit, 0),
     CASE WHEN v_settlement_profit <> 0 THEN v_cash_cur ELSE NULL END);

  RETURN jsonb_build_object(
    'success', true,
    'newSaldo', v_new_saldo,
    'saldoCurrency', v_saldo_cur,
    'settlementProfit', v_settlement_profit,
    'settlementProfitCurrency', v_cash_cur
  );
END;
$fn$;

-- ─────────────────────────────────────────────────────────────
-- 3. #26 — нормализация легаси-роли 'admin' в RLS на is_creator()
-- ─────────────────────────────────────────────────────────────
-- Каждая политика: DROP старой + CREATE замены с тем же именем/
-- таблицей/командой. Before/after предикат — у каждой.

-- 3.1 public.users — INSERT --------------------------------------
--   before: WITH CHECK (id = auth.uid()
--                       OR private.get_user_role() IN ('creator','admin'))
--   after : WITH CHECK (id = auth.uid() OR private.is_creator())
--   self-insert (id = auth.uid(), используется триггером регистрации
--   008) сохраняется; legacy-ветка 'admin' схлопывается в is_creator().
DROP POLICY IF EXISTS "users_insert" ON public.users;
CREATE POLICY "users_insert" ON public.users FOR INSERT TO authenticated
  WITH CHECK (
    id = auth.uid()
    OR private.is_creator()
  );

-- 3.2 public.users — UPDATE --------------------------------------
--   before: USING (private.get_user_role() IN ('creator','admin')
--                  OR id = auth.uid())
--   after : USING (private.is_creator() OR id = auth.uid())
--   self-update (ограничен триггером users_guard_self_edit, 013)
--   сохраняется; legacy-ветка 'admin' схлопывается в is_creator().
DROP POLICY IF EXISTS "users_update" ON public.users;
CREATE POLICY "users_update" ON public.users FOR UPDATE TO authenticated
  USING (
    private.is_creator()
    OR id = auth.uid()
  );

-- 3.3 public.users — DELETE --------------------------------------
--   before: USING (private.get_user_role() IN ('creator','admin'))
--   after : USING (private.is_creator())
DROP POLICY IF EXISTS "users_delete" ON public.users;
CREATE POLICY "users_delete" ON public.users FOR DELETE TO authenticated
  USING (private.is_creator());

-- 3.4 public.audit_logs — SELECT ---------------------------------
--   before: USING (private.get_user_role() IN ('creator','admin'))
--   after : USING (private.is_creator())
--   Доступ к аудиту был creator+admin (НЕ director) — сохраняем
--   creator-only, директора НЕ добавляем (грант не расширяем).
DROP POLICY IF EXISTS "audit_select" ON public.audit_logs;
CREATE POLICY "audit_select" ON public.audit_logs FOR SELECT TO authenticated
  USING (private.is_creator());

-- 3.5 public.system_audit_logs — SELECT --------------------------
--   before: USING (private.get_user_role() IN ('creator','admin'))
--   after : USING (private.is_creator())
DROP POLICY IF EXISTS "sys_audit_select" ON public.system_audit_logs;
CREATE POLICY "sys_audit_select" ON public.system_audit_logs FOR SELECT TO authenticated
  USING (private.is_creator());

COMMIT;
