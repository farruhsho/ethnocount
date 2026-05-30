-- ============================================================
-- 039: Lifecycle fixes + delete_transfer
-- ============================================================
-- Полный аудит цикла create → confirm → dispatch → issue выявил
-- три критичных проблемы:
--
-- 1) `dispatch_transfer_to_courier` (миграция 022) обращается к
--    несуществующим колонкам `users.user_id` и `users.system_role` —
--    в реальной схеме (миграция 001) колонки называются `id` и `role`.
--    Это означает, что отправка перевода курьеру всегда падает с
--    «column user_id does not exist» для бухгалтера. Тихий блокер.
--
-- 2) Нет RPC для отмены/удаления ошибочно созданного перевода. После
--    миграции 022 `cancel_transfer` и `reject_transfer` были удалены,
--    но новый delete-механизм не добавлен. В результате если оператор
--    создал перевод с опечаткой в сумме — нет легального способа его
--    откатить. Это особенно критично для партнёрских переводов
--    (status='delivered' сразу), где даже status guard не позволяет
--    UPDATE.
--
-- 3) `transfer_profit_summary` и `partner_profit_top_partners`
--    (миграция 036) фильтруют `status NOT IN ('cancelled','rejected')`
--    — эти статусы уничтожены в 022 и не вернутся. Фильтр устарел,
--    замусоривает план запроса. Убираем.
--
-- Что добавляем:
--   • `public.deleted_transfers` (аудит-таблица + RLS)
--   • `delete_transfer(p_transfer_id, p_reason)` — atomic reversal:
--       - refund source account
--       - reverse commission credit (если fromAccount)
--       - reverse partner saldo (если via_counterparty_id)
--       - delete ledger_entries / commissions / counterparty_tx
--       - INSERT into deleted_transfers (snapshot)
--       - DELETE from transfers
--     Разрешено:
--       - creator/director: всегда, любой status
--       - accountant: только status='created' (свой pending) И не
--         partner (партнёрские всегда delivered, и в них вмешательство
--         в saldo рискованно — пусть director решает).
--     Запрещено для:
--       - toDelivery / withCourier / delivered (обычный) — receiver
--         уже credited, нужен другой workflow (replace_pending или
--         direct manual rollback директором).
--       - delivered + via_counterparty_id: разрешено creator/director
--         (откат saldo партнёра атомарно).
--
-- Перепишем dispatch_transfer_to_courier правильно.
--
-- Идемпотентно — CREATE OR REPLACE / IF NOT EXISTS.
-- ============================================================

BEGIN;

-- ─── 1. Аудит-таблица отменённых переводов ───────────────────
CREATE TABLE IF NOT EXISTS public.deleted_transfers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  original_id uuid NOT NULL,
  transaction_code text,
  from_branch_id uuid,
  to_branch_id uuid,
  from_account_id uuid,
  amount double precision,
  currency text,
  to_currency text,
  status_at_delete text,
  via_counterparty_id uuid,
  deleted_by uuid REFERENCES auth.users(id),
  deleted_at timestamptz NOT NULL DEFAULT now(),
  reason text,
  original_data jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_deleted_transfers_deleted_at
  ON public.deleted_transfers (deleted_at DESC);
CREATE INDEX IF NOT EXISTS idx_deleted_transfers_branch
  ON public.deleted_transfers (from_branch_id);

ALTER TABLE public.deleted_transfers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS deleted_transfers_select ON public.deleted_transfers;
CREATE POLICY deleted_transfers_select ON public.deleted_transfers
  FOR SELECT TO authenticated USING (true);


-- ─── 2. Fix dispatch_transfer_to_courier (users.id/role) ─────
CREATE OR REPLACE FUNCTION private.dispatch_transfer_to_courier(
  p_transfer_id   uuid,
  p_courier_name  text DEFAULT NULL,
  p_courier_phone text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_transfer transfers%ROWTYPE;
  v_role text;
  v_assigned text[];
  v_code text;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_transfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Transfer not found'; END IF;
  IF v_transfer.status <> 'toDelivery' THEN
    RAISE EXCEPTION 'Курьеру можно отдать только перевод «к выдаче» (текущий: %)', v_transfer.status;
  END IF;

  -- Правильные имена колонок (миграция 022 использовала несуществующие
  -- user_id / system_role / branch_id).
  SELECT role::text, assigned_branch_ids
    INTO v_role, v_assigned
    FROM public.users WHERE id = v_user_id;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'Профиль пользователя не найден';
  END IF;

  -- creator/director — без ограничений. accountant — только если
  -- from_branch_id есть в его assigned_branch_ids.
  IF v_role = 'accountant' THEN
    IF v_assigned IS NULL
       OR NOT (v_transfer.from_branch_id::text = ANY(v_assigned)) THEN
      RAISE EXCEPTION 'Только бухгалтер отправляющего филиала может отдать перевод курьеру';
    END IF;
  END IF;

  v_code := COALESCE(v_transfer.transaction_code, p_transfer_id::text);

  UPDATE transfers SET
    status        = 'withCourier',
    dispatched_by = v_user_id,
    dispatched_at = now(),
    courier_name  = NULLIF(trim(coalesce(p_courier_name,'')), ''),
    courier_phone = NULLIF(trim(coalesce(p_courier_phone,'')), '')
  WHERE id = p_transfer_id;

  INSERT INTO notifications (target_branch_id, type, title, body, data) VALUES
    (
      v_transfer.to_branch_id::text,
      'transfer_dispatched',
      'Перевод ' || v_code || ' у курьера',
      'Деньги переданы курьеру'
        || COALESCE(' (' || NULLIF(trim(p_courier_name),'') || ')', ''),
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code,
        'courierName', NULLIF(trim(coalesce(p_courier_name,'')), ''),
        'courierPhone', NULLIF(trim(coalesce(p_courier_phone,'')), '')
      )
    ),
    (
      v_transfer.from_branch_id::text,
      'transfer_dispatched',
      'Перевод ' || v_code || ' отправлен курьером',
      'Вы передали наличные курьеру для доставки в '
        || COALESCE((SELECT name FROM branches WHERE id = v_transfer.to_branch_id), '—'),
      jsonb_build_object(
        'transferId', p_transfer_id::text,
        'transactionCode', v_code
      )
    );

  RETURN jsonb_build_object('success', true);
END;
$$;

GRANT EXECUTE ON FUNCTION private.dispatch_transfer_to_courier(uuid, text, text)
  TO authenticated;


-- ─── 3. delete_transfer (atomic reversal) ────────────────────
CREATE OR REPLACE FUNCTION private.delete_transfer(
  p_transfer_id uuid,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_assigned text[];
  v_t transfers%ROWTYPE;
  v_total_debit double precision;
  v_op_amount double precision;
  v_op_currency text;
  v_curr_saldo double precision;
  v_snapshot jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT role::text, assigned_branch_ids
    INTO v_role, v_assigned
    FROM public.users WHERE id = v_uid;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'Профиль пользователя не найден';
  END IF;

  SELECT * INTO v_t FROM transfers
    WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;

  -- ── Проверка прав ────────────────────────────────────────
  IF v_role = 'accountant' THEN
    IF v_t.status <> 'created' OR v_t.via_counterparty_id IS NOT NULL THEN
      RAISE EXCEPTION 'Бухгалтер может удалить только свой созданный (pending) перевод. '
                  'Партнёрские и confirmed-переводы — только Director/Creator.';
    END IF;
    -- Свой филиал.
    IF v_assigned IS NULL
       OR NOT (v_t.from_branch_id::text = ANY(v_assigned)) THEN
      RAISE EXCEPTION 'Можно удалить только переводы из своего филиала';
    END IF;
  END IF;

  -- ── Какие статусы разрешены ─────────────────────────────
  -- created                       — обычный pending, всегда можно
  -- delivered + via_counterparty  — партнёрский (только director/creator)
  IF NOT (
       v_t.status = 'created'
       OR (v_t.status = 'delivered' AND v_t.via_counterparty_id IS NOT NULL)
     ) THEN
    RAISE EXCEPTION 'Удаление возможно для статуса «created» или для партнёрских «delivered». '
                'Текущий: %. '
                'Confirmed/withCourier/delivered (обычные) уже задели счёт получателя, '
                'отмена требует ручного rollback директором.', v_t.status;
  END IF;

  -- Snapshot для аудита.
  v_snapshot := to_jsonb(v_t);

  -- ── REFUND: основной счёт-источник ──────────────────────
  IF v_t.commission_mode = 'fromSender' THEN
    v_total_debit := v_t.amount + COALESCE(v_t.commission, 0);
  ELSE
    v_total_debit := v_t.amount;
  END IF;
  IF v_t.from_account_id IS NOT NULL THEN
    UPDATE account_balances
       SET balance    = balance + v_total_debit,
           updated_at = now()
     WHERE account_id = v_t.from_account_id;
  END IF;

  -- ── REVERSE: commission credit (если fromAccount) ───────
  IF v_t.commission_mode = 'fromAccount'
     AND v_t.commission_account_id IS NOT NULL
     AND COALESCE(v_t.commission, 0) > 0 THEN
    UPDATE account_balances
       SET balance    = balance - v_t.commission,
           updated_at = now()
     WHERE account_id = v_t.commission_account_id;
  END IF;

  -- ── REVERSE: partner saldo (если via_counterparty_id) ───
  IF v_t.via_counterparty_id IS NOT NULL THEN
    -- Находим paid_for_us op, чтобы знать ровно ту валюту/сумму
    -- которой мы двигали saldo. Их может быть несколько (теоретически),
    -- — берём все и откатываем.
    FOR v_op_amount, v_op_currency IN
      SELECT amount, currency FROM counterparty_transactions
       WHERE transfer_id = p_transfer_id
         AND kind = 'paid_for_us'
    LOOP
      v_curr_saldo := COALESCE(
        ((SELECT saldo_by_currency->>v_op_currency
            FROM counterparties WHERE id = v_t.via_counterparty_id)::double precision),
        0);
      -- paid_for_us изначально делал saldo -= amount → откатываем += amount.
      UPDATE counterparties
         SET saldo_by_currency = saldo_by_currency
             || jsonb_build_object(v_op_currency, v_curr_saldo + v_op_amount)
       WHERE id = v_t.via_counterparty_id;
    END LOOP;

    DELETE FROM counterparty_transactions WHERE transfer_id = p_transfer_id;
  END IF;

  -- ── DELETE: ledger entries + commissions + approvals ────
  DELETE FROM ledger_entries
   WHERE reference_id = p_transfer_id::text
     AND reference_type IN ('transfer', 'commission', 'transfer_issuance');
  DELETE FROM commissions WHERE transfer_id = p_transfer_id;
  DELETE FROM transfer_issuances WHERE transfer_id = p_transfer_id;
  DELETE FROM pending_approvals WHERE target_id = p_transfer_id;

  -- ── Аудит ────────────────────────────────────────────────
  INSERT INTO deleted_transfers (
    original_id, transaction_code,
    from_branch_id, to_branch_id, from_account_id,
    amount, currency, to_currency,
    status_at_delete, via_counterparty_id,
    deleted_by, reason, original_data
  ) VALUES (
    v_t.id, v_t.transaction_code,
    v_t.from_branch_id, v_t.to_branch_id, v_t.from_account_id,
    v_t.amount, v_t.currency, v_t.to_currency,
    v_t.status, v_t.via_counterparty_id,
    v_uid, NULLIF(trim(coalesce(p_reason,'')), ''), v_snapshot
  );

  -- ── Hard delete ──────────────────────────────────────────
  DELETE FROM transfers WHERE id = p_transfer_id;

  RETURN jsonb_build_object(
    'success', true,
    'refundedAmount', v_total_debit,
    'refundedCurrency', v_t.currency
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_transfer(
  p_transfer_id uuid,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.delete_transfer(p_transfer_id, p_reason);
$$;

GRANT EXECUTE ON FUNCTION public.delete_transfer(uuid, text) TO authenticated;


-- ─── 4. Cleanup obsolete status filter ───────────────────────
-- Уже rejected/cancelled больше не существуют (миграция 022). Старый
-- фильтр был «защитный» — теперь это шум в плане. Перезаписываем без
-- него. Семантика остаётся та же.
CREATE OR REPLACE FUNCTION private.transfer_profit_summary(
  p_branch_id     uuid DEFAULT NULL,
  p_start         timestamptz DEFAULT NULL,
  p_end           timestamptz DEFAULT NULL,
  p_partner_only  boolean DEFAULT false
) RETURNS TABLE (
  branch_id uuid,
  currency text,
  transfer_count bigint,
  total_volume double precision,
  spread_profit double precision,
  commission_profit double precision,
  is_partner boolean
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH base AS (
    SELECT
      t.id,
      t.from_branch_id AS branch_id,
      t.currency,
      t.amount,
      COALESCE(t.spread_profit, 0) AS spread,
      (t.via_counterparty_id IS NOT NULL) AS is_partner
    FROM transfers t
    WHERE (p_branch_id IS NULL OR t.from_branch_id = p_branch_id)
      AND (p_start IS NULL OR t.created_at >= p_start)
      AND (p_end   IS NULL OR t.created_at <  p_end)
      AND (NOT p_partner_only OR t.via_counterparty_id IS NOT NULL)
  ),
  comm AS (
    SELECT
      c.transfer_id,
      c.currency,
      SUM(c.amount) AS commission_total
    FROM commissions c
    WHERE c.transfer_id IN (SELECT id FROM base)
    GROUP BY c.transfer_id, c.currency
  )
  SELECT
    b.branch_id,
    b.currency,
    COUNT(*)::bigint AS transfer_count,
    SUM(b.amount) AS total_volume,
    SUM(b.spread) AS spread_profit,
    COALESCE(SUM(
      (SELECT commission_total FROM comm
       WHERE comm.transfer_id = b.id AND comm.currency = b.currency)
    ), 0) AS commission_profit,
    bool_or(b.is_partner) AS is_partner
  FROM base b
  GROUP BY b.branch_id, b.currency
  ORDER BY total_volume DESC NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION private.partner_profit_top_partners(
  p_start timestamptz DEFAULT NULL,
  p_end   timestamptz DEFAULT NULL,
  p_limit int DEFAULT 5
) RETURNS TABLE (
  counterparty_id uuid,
  name text,
  city text,
  transfer_count bigint,
  total_volume_usd_proxy double precision,
  total_spread_proxy double precision,
  total_commission_proxy double precision
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH base AS (
    SELECT
      t.id,
      t.via_counterparty_id,
      t.amount,
      t.currency,
      COALESCE(t.spread_profit, 0) AS spread,
      CASE
        WHEN t.buy_rate IS NULL OR t.buy_rate = 0 THEN t.amount
        ELSE t.amount / t.buy_rate
      END AS amount_norm
    FROM transfers t
    WHERE t.via_counterparty_id IS NOT NULL
      AND (p_start IS NULL OR t.created_at >= p_start)
      AND (p_end   IS NULL OR t.created_at <  p_end)
  ),
  comm AS (
    SELECT c.transfer_id, SUM(c.amount) AS commission_total
    FROM commissions c
    WHERE c.transfer_id IN (SELECT id FROM base)
    GROUP BY c.transfer_id
  )
  SELECT
    b.via_counterparty_id AS counterparty_id,
    cp.name,
    cp.city,
    COUNT(*)::bigint AS transfer_count,
    SUM(b.amount_norm) AS total_volume_usd_proxy,
    SUM(b.spread) AS total_spread_proxy,
    COALESCE(SUM(
      (SELECT commission_total FROM comm WHERE comm.transfer_id = b.id)
    ), 0) AS total_commission_proxy
  FROM base b
  JOIN counterparties cp ON cp.id = b.via_counterparty_id
  GROUP BY b.via_counterparty_id, cp.name, cp.city
  ORDER BY SUM(b.amount_norm) DESC NULLS LAST
  LIMIT p_limit;
$$;

-- partner_profit_monthly (037) — также убираем status-фильтр для
-- согласованности с остальным dashboard-ом.
CREATE OR REPLACE FUNCTION private.partner_profit_monthly(
  p_start         timestamptz DEFAULT NULL,
  p_end           timestamptz DEFAULT NULL,
  p_partner_only  boolean DEFAULT true,
  p_counterparty_id uuid DEFAULT NULL
) RETURNS TABLE (
  month_start  timestamptz,
  currency     text,
  transfer_count bigint,
  total_volume double precision,
  spread_profit double precision,
  commission_profit double precision
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH base AS (
    SELECT
      t.id,
      date_trunc('month', t.created_at) AS month_start,
      t.currency,
      t.amount,
      COALESCE(t.spread_profit, 0) AS spread
    FROM transfers t
    WHERE (p_start IS NULL OR t.created_at >= p_start)
      AND (p_end   IS NULL OR t.created_at <  p_end)
      AND (NOT p_partner_only OR t.via_counterparty_id IS NOT NULL)
      AND (p_counterparty_id IS NULL
           OR t.via_counterparty_id = p_counterparty_id)
  ),
  comm AS (
    SELECT
      c.transfer_id,
      c.currency,
      SUM(c.amount) AS commission_total
    FROM commissions c
    WHERE c.transfer_id IN (SELECT id FROM base)
    GROUP BY c.transfer_id, c.currency
  )
  SELECT
    b.month_start,
    b.currency,
    COUNT(*)::bigint AS transfer_count,
    SUM(b.amount) AS total_volume,
    SUM(b.spread) AS spread_profit,
    COALESCE(SUM(
      (SELECT commission_total FROM comm
       WHERE comm.transfer_id = b.id AND comm.currency = b.currency)
    ), 0) AS commission_profit
  FROM base b
  GROUP BY b.month_start, b.currency
  ORDER BY b.month_start ASC, b.currency ASC;
$$;

COMMIT;
