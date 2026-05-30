-- ============================================================
-- 041: attach_transfer_to_partner + branch-scoped analytics
-- ============================================================
-- 1) Прикрепление уже созданного перевода к партнёру:
--    Сценарий — бухгалтер сначала создал обычный перевод (без
--    via_counterparty_id), потом понял что выплата шла через партнёра.
--    Раньше пришлось бы удалять и создавать заново. Теперь:
--
--      SELECT attach_transfer_to_partner(transfer_id, counterparty_id,
--        payout_method, buy_rate, sell_rate, base_currency);
--
--    Что делает:
--      • SET transfers.via_counterparty_id = p_counterparty_id
--      • Если переданы buy/sell/base → пересчитывает spread_profit
--      • INSERT counterparty_transactions(kind='paid_for_us', amount,
--        currency, transfer_id, payout_method, exchange_rate=buy_rate)
--      • Двигает saldo партнёра вниз (мы теперь должны через него)
--      • Идемпотентно: если transfer уже прикреплён к ТОМУ ЖЕ
--        партнёру — обновляет курсы, saldo НЕ двигает повторно.
--        Если к другому — отказывает (нужно сначала detach).
--
--    Доступ: creator/director всегда; accountant — только свой
--    pending-перевод (status='created').
--
-- 2) `partner_profit_top_partners` расширен `p_branch_id` фильтром —
--    бухгалтер увидит топ только по своему филиалу.
--
-- 3) Detach (откат прикрепления) — для исправления ошибки:
--      SELECT detach_transfer_from_partner(transfer_id);
--
-- Идемпотентно. CREATE OR REPLACE / DROP IF EXISTS.
-- ============================================================

BEGIN;

-- ─── 1. attach_transfer_to_partner ───────────────────────────
CREATE OR REPLACE FUNCTION private.attach_transfer_to_partner(
  p_transfer_id      uuid,
  p_counterparty_id  uuid,
  p_payout_method    text DEFAULT 'cash',
  p_buy_rate         double precision DEFAULT NULL,
  p_sell_rate        double precision DEFAULT NULL,
  p_base_currency    text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_assigned text[];
  v_t transfers%ROWTYPE;
  v_cp counterparties%ROWTYPE;
  v_new_spread double precision;
  v_owes_amount double precision;
  v_owes_currency text;
  v_already_attached boolean := false;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT role::text, assigned_branch_ids
    INTO v_role, v_assigned
    FROM public.users WHERE id = v_uid;

  SELECT * INTO v_t FROM transfers
    WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;

  SELECT * INTO v_cp FROM counterparties
    WHERE id = p_counterparty_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;
  IF NOT v_cp.is_active THEN
    RAISE EXCEPTION 'Партнёр архивирован';
  END IF;

  -- ── Права ───────────────────────────────────────────────
  IF v_role = 'accountant' THEN
    IF v_t.status <> 'created' THEN
      RAISE EXCEPTION 'Бухгалтер может прикрепить только перевод в статусе created. Текущий: %', v_t.status;
    END IF;
    IF v_assigned IS NULL OR NOT (v_t.from_branch_id::text = ANY(v_assigned)) THEN
      RAISE EXCEPTION 'Можно прикреплять только переводы из своего филиала';
    END IF;
  END IF;

  -- ── Конфликты ───────────────────────────────────────────
  IF v_t.via_counterparty_id IS NOT NULL THEN
    IF v_t.via_counterparty_id <> p_counterparty_id THEN
      RAISE EXCEPTION 'Перевод уже привязан к другому партнёру. Сначала detach.';
    END IF;
    v_already_attached := true;
  END IF;

  -- ── Считаем spread, если переданы buy/sell ──────────────
  IF p_buy_rate IS NOT NULL AND p_sell_rate IS NOT NULL THEN
    IF p_buy_rate <= 0 OR p_sell_rate <= 0 THEN
      RAISE EXCEPTION 'Курсы должны быть > 0';
    END IF;
    IF p_base_currency IS NULL OR length(trim(p_base_currency)) = 0 THEN
      RAISE EXCEPTION 'Для дилерской модели нужна base_currency';
    END IF;
    IF trim(p_base_currency) = v_t.currency THEN
      v_new_spread := 0;
    ELSE
      v_new_spread := private.calc_spread_profit(
        v_t.amount, p_buy_rate, p_sell_rate);
    END IF;
  END IF;

  -- ── Обновляем transfer ─────────────────────────────────
  UPDATE transfers SET
    via_counterparty_id = p_counterparty_id,
    buy_rate       = COALESCE(p_buy_rate, buy_rate),
    sell_rate      = COALESCE(p_sell_rate, sell_rate),
    base_currency  = COALESCE(NULLIF(trim(p_base_currency), ''), base_currency),
    spread_profit  = COALESCE(v_new_spread, spread_profit),
    amendment_history = COALESCE(amendment_history, '[]'::jsonb) ||
      jsonb_build_array(
        jsonb_build_object(
          'at',     now(),
          'userId', v_uid::text,
          'kind',   'attach_to_partner',
          'changes', jsonb_build_object(
            'counterparty_id', p_counterparty_id::text,
            'partner_name',    v_cp.name,
            'buy_rate',        p_buy_rate,
            'sell_rate',       p_sell_rate,
            'base_currency',   p_base_currency,
            'spread_profit',   v_new_spread
          )
        )
      )
  WHERE id = p_transfer_id;

  -- ── Если уже было прикреплено — не двигаем saldo повторно ──
  IF v_already_attached THEN
    RETURN jsonb_build_object(
      'success', true,
      'reattached', true,
      'newSpread', v_new_spread
    );
  END IF;

  -- ── Считаем какую сумму партнёр нам должен ─────────────
  -- Если есть buy_rate + base_currency != currency → saldo в base.
  -- Иначе saldo в валюте перевода (same-currency fallback).
  IF p_buy_rate IS NOT NULL AND p_buy_rate > 0
     AND p_base_currency IS NOT NULL
     AND trim(p_base_currency) <> v_t.currency THEN
    v_owes_amount := v_t.amount / p_buy_rate;
    v_owes_currency := upper(trim(p_base_currency));
  ELSE
    v_owes_amount := v_t.amount;
    v_owes_currency := v_t.currency;
  END IF;

  -- ── Двигаем saldo + пишем counterparty_transactions ────
  PERFORM private.record_counterparty_op(
    p_counterparty_id := p_counterparty_id,
    p_kind            := 'paid_for_us',
    p_amount          := v_owes_amount,
    p_currency        := v_owes_currency,
    p_description     := 'Прикреплено: ' || COALESCE(v_t.transaction_code, p_transfer_id::text)
                         || COALESCE(' получатель ' || v_t.receiver_name, ''),
    p_cash_account_id := NULL,
    p_transfer_id     := p_transfer_id,
    p_payout_method   := COALESCE(NULLIF(trim(p_payout_method), ''), 'cash'),
    p_exchange_rate   := p_buy_rate
  );

  RETURN jsonb_build_object(
    'success', true,
    'transferId', p_transfer_id::text,
    'counterpartyId', p_counterparty_id::text,
    'partnerName', v_cp.name,
    'owesAmount', v_owes_amount,
    'owesCurrency', v_owes_currency,
    'spreadProfit', COALESCE(v_new_spread, 0)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.attach_transfer_to_partner(
  p_transfer_id      uuid,
  p_counterparty_id  uuid,
  p_payout_method    text DEFAULT 'cash',
  p_buy_rate         double precision DEFAULT NULL,
  p_sell_rate        double precision DEFAULT NULL,
  p_base_currency    text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.attach_transfer_to_partner(
    p_transfer_id, p_counterparty_id, p_payout_method,
    p_buy_rate, p_sell_rate, p_base_currency);
$$;

GRANT EXECUTE ON FUNCTION public.attach_transfer_to_partner(
  uuid, uuid, text, double precision, double precision, text
) TO authenticated;


-- ─── 2. detach_transfer_from_partner ─────────────────────────
CREATE OR REPLACE FUNCTION private.detach_transfer_from_partner(
  p_transfer_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_assigned text[];
  v_t transfers%ROWTYPE;
  v_op_amount double precision;
  v_op_currency text;
  v_curr_saldo double precision;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  SELECT role::text, assigned_branch_ids INTO v_role, v_assigned
    FROM public.users WHERE id = v_uid;

  SELECT * INTO v_t FROM transfers
    WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Перевод не найден'; END IF;
  IF v_t.via_counterparty_id IS NULL THEN
    RAISE EXCEPTION 'Перевод не привязан к партнёру';
  END IF;

  IF v_role = 'accountant' THEN
    IF v_t.status <> 'created' THEN
      RAISE EXCEPTION 'Бухгалтер может откреплять только created-переводы';
    END IF;
    IF v_assigned IS NULL OR NOT (v_t.from_branch_id::text = ANY(v_assigned)) THEN
      RAISE EXCEPTION 'Чужой филиал';
    END IF;
  END IF;

  -- Reverse saldo по всем paid_for_us для этого перевода.
  FOR v_op_amount, v_op_currency IN
    SELECT amount, currency FROM counterparty_transactions
     WHERE transfer_id = p_transfer_id AND kind = 'paid_for_us'
  LOOP
    v_curr_saldo := COALESCE(
      ((SELECT saldo_by_currency->>v_op_currency
          FROM counterparties WHERE id = v_t.via_counterparty_id)::double precision),
      0);
    UPDATE counterparties
       SET saldo_by_currency = saldo_by_currency
           || jsonb_build_object(v_op_currency, v_curr_saldo + v_op_amount)
     WHERE id = v_t.via_counterparty_id;
  END LOOP;

  DELETE FROM counterparty_transactions
   WHERE transfer_id = p_transfer_id AND kind = 'paid_for_us';

  UPDATE transfers SET
    via_counterparty_id = NULL,
    spread_profit = NULL,
    amendment_history = COALESCE(amendment_history, '[]'::jsonb) ||
      jsonb_build_array(
        jsonb_build_object(
          'at', now(),
          'userId', v_uid::text,
          'kind', 'detach_from_partner'
        ))
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.detach_transfer_from_partner(
  p_transfer_id uuid
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.detach_transfer_from_partner(p_transfer_id); $$;

GRANT EXECUTE ON FUNCTION public.detach_transfer_from_partner(uuid) TO authenticated;


-- ─── 3. RPC «список переводов готовых к прикреплению» ────────
-- Бухгалтер выбирает из своего филиала, директор/creator — отовсюду.
CREATE OR REPLACE FUNCTION private.transfers_attachable_to_partner(
  p_search text DEFAULT NULL,
  p_limit int DEFAULT 50
) RETURNS TABLE (
  id uuid,
  transaction_code text,
  amount double precision,
  currency text,
  receiver_name text,
  receiver_phone text,
  created_at timestamptz,
  status text,
  from_branch_name text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_assigned text[];
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'auth'; END IF;
  SELECT role::text, assigned_branch_ids INTO v_role, v_assigned
    FROM public.users WHERE id = v_uid;

  RETURN QUERY
  SELECT
    t.id,
    t.transaction_code,
    t.amount,
    t.currency,
    t.receiver_name,
    t.receiver_phone,
    t.created_at,
    t.status::text,
    b.name AS from_branch_name
  FROM transfers t
  LEFT JOIN branches b ON b.id = t.from_branch_id
  WHERE t.via_counterparty_id IS NULL
    AND (v_role <> 'accountant'
         OR v_assigned IS NULL
         OR t.from_branch_id::text = ANY(v_assigned))
    AND (p_search IS NULL
         OR p_search = ''
         OR t.transaction_code ILIKE '%' || p_search || '%'
         OR COALESCE(t.receiver_name, '') ILIKE '%' || p_search || '%'
         OR COALESCE(t.receiver_phone, '') ILIKE '%' || p_search || '%')
  ORDER BY t.created_at DESC
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.transfers_attachable_to_partner(
  p_search text DEFAULT NULL,
  p_limit int DEFAULT 50
) RETURNS TABLE (
  id uuid,
  transaction_code text,
  amount double precision,
  currency text,
  receiver_name text,
  receiver_phone text,
  created_at timestamptz,
  status text,
  from_branch_name text
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT * FROM private.transfers_attachable_to_partner(p_search, p_limit); $$;

GRANT EXECUTE ON FUNCTION public.transfers_attachable_to_partner(text, int)
  TO authenticated;


-- ─── 4. partner_profit_top_partners с branch-фильтром ────────
DROP FUNCTION IF EXISTS public.partner_profit_top_partners(
  timestamptz, timestamptz, int);

CREATE OR REPLACE FUNCTION private.partner_profit_top_partners(
  p_start timestamptz DEFAULT NULL,
  p_end   timestamptz DEFAULT NULL,
  p_limit int DEFAULT 5,
  p_branch_id uuid DEFAULT NULL
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
      AND (p_branch_id IS NULL OR t.from_branch_id = p_branch_id)
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

CREATE OR REPLACE FUNCTION public.partner_profit_top_partners(
  p_start timestamptz DEFAULT NULL,
  p_end   timestamptz DEFAULT NULL,
  p_limit int DEFAULT 5,
  p_branch_id uuid DEFAULT NULL
) RETURNS TABLE (
  counterparty_id uuid,
  name text,
  city text,
  transfer_count bigint,
  total_volume_usd_proxy double precision,
  total_spread_proxy double precision,
  total_commission_proxy double precision
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.partner_profit_top_partners(
    p_start, p_end, p_limit, p_branch_id);
$$;

GRANT EXECUTE ON FUNCTION public.partner_profit_top_partners(
  timestamptz, timestamptz, int, uuid
) TO authenticated;


-- ─── 5. partner_profit_monthly с branch-фильтром ─────────────
DROP FUNCTION IF EXISTS public.partner_profit_monthly(
  timestamptz, timestamptz, boolean, uuid);

CREATE OR REPLACE FUNCTION private.partner_profit_monthly(
  p_start         timestamptz DEFAULT NULL,
  p_end           timestamptz DEFAULT NULL,
  p_partner_only  boolean DEFAULT true,
  p_counterparty_id uuid DEFAULT NULL,
  p_branch_id     uuid DEFAULT NULL
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
      AND (p_branch_id IS NULL OR t.from_branch_id = p_branch_id)
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

CREATE OR REPLACE FUNCTION public.partner_profit_monthly(
  p_start         timestamptz DEFAULT NULL,
  p_end           timestamptz DEFAULT NULL,
  p_partner_only  boolean DEFAULT true,
  p_counterparty_id uuid DEFAULT NULL,
  p_branch_id     uuid DEFAULT NULL
) RETURNS TABLE (
  month_start  timestamptz,
  currency     text,
  transfer_count bigint,
  total_volume double precision,
  spread_profit double precision,
  commission_profit double precision
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.partner_profit_monthly(
    p_start, p_end, p_partner_only, p_counterparty_id, p_branch_id);
$$;

GRANT EXECUTE ON FUNCTION public.partner_profit_monthly(
  timestamptz, timestamptz, boolean, uuid, uuid
) TO authenticated;

COMMIT;
