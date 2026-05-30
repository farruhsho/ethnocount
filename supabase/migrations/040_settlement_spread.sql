-- ============================================================
-- 040: Cross-currency settlement spread
-- ============================================================
-- Закрываем последний пробел партнёрской дилерской модели.
--
-- Сценарий:
--   У партнёра saldo[USD] = -1000 (мы должны ему 1000 USD).
--   Партнёр приехал в Ташкент за расчётом. Ему удобнее получить
--   наличные UZS, не USD. По расчётной ставке (sell_rate ~12500)
--   мы должны были бы отдать 12 500 000 UZS, но фактически отдали
--   12 300 000 UZS. Spread = 200 000 UZS = settlement profit.
--
-- Текущая логика 033: `record_counterparty_op(settle_*)` требует
-- `p_currency = p_cash_account.currency`, и saldo[currency] -= amount.
-- Cross-currency settle не поддерживается.
--
-- Что добавляем:
--
-- 1) Колонки в counterparty_transactions:
--    closes_amount, closes_currency  — что фактически закрыто из saldo
--                                       (в его «своей» валюте долга).
--    expected_rate                    — ожидаемый курс (если указан).
--    settlement_profit               — кэш расчётной прибыли (или -убытка)
--    settlement_profit_currency      — валюта профита (= currency,
--                                       т.к. это разница в local cash).
--
-- 2) `record_counterparty_op` принимает новые опциональные параметры:
--    p_close_amount, p_close_currency, p_expected_rate.
--    Логика:
--      - Если p_close_currency = p_currency (или NULL) → старое поведение
--        (same-currency settle, как было). settlement_profit = 0.
--      - Если разные:
--          • двигаем saldo[close_currency] на close_amount (вместо
--            saldo[currency] на amount);
--          • cash-счёт по-прежнему двигается на amount в currency;
--          • если p_expected_rate указан — считаем settlement_profit.
--
-- 3) `partner_profit_summary` (036) → добавить settlement_profit колонку.
--
-- Идемпотентно — IF NOT EXISTS + CREATE OR REPLACE.
-- ============================================================

BEGIN;

-- ─── 1. Колонки в counterparty_transactions ──────────────────
ALTER TABLE public.counterparty_transactions
  ADD COLUMN IF NOT EXISTS closes_amount        double precision,
  ADD COLUMN IF NOT EXISTS closes_currency      text,
  ADD COLUMN IF NOT EXISTS expected_rate        double precision,
  ADD COLUMN IF NOT EXISTS settlement_profit    double precision,
  ADD COLUMN IF NOT EXISTS settlement_profit_currency text;

COMMENT ON COLUMN public.counterparty_transactions.closes_amount IS
  'Сколько закрыто из saldo (в closes_currency). NULL → same-currency, equal to amount.';
COMMENT ON COLUMN public.counterparty_transactions.settlement_profit IS
  'Курсовая прибыль/убыток на settlement-е, в settlement_profit_currency. '
  'Положительный — мы выиграли; отрицательный — переплатили.';


-- ─── 2. record_counterparty_op v3 (cross-currency settle) ────
-- Drop предыдущие варианты, чтобы public-обёртка резолвилась однозначно.
DROP FUNCTION IF EXISTS private.record_counterparty_op(
  uuid, text, double precision, text, text);
DROP FUNCTION IF EXISTS private.record_counterparty_op(
  uuid, text, double precision, text, text, uuid, uuid, text, double precision);

CREATE OR REPLACE FUNCTION private.record_counterparty_op(
  p_counterparty_id uuid,
  p_kind text,
  p_amount double precision,
  p_currency text,
  p_description text DEFAULT NULL,
  p_cash_account_id uuid DEFAULT NULL,
  p_transfer_id uuid DEFAULT NULL,
  p_payout_method text DEFAULT NULL,
  p_exchange_rate double precision DEFAULT NULL,
  -- Cross-currency settle:
  p_close_amount   double precision DEFAULT NULL,
  p_close_currency text DEFAULT NULL,
  p_expected_rate  double precision DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
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

  -- Resolve close_amount/currency. Если не указаны — same-currency.
  v_saldo_cur := upper(COALESCE(NULLIF(trim(p_close_currency), ''), v_cash_cur));
  v_close_amount := COALESCE(p_close_amount, p_amount);
  IF v_close_amount <= 0 THEN
    RAISE EXCEPTION 'closes_amount должен быть > 0';
  END IF;

  -- Saldo delta зависит от kind: знак, и валюта (close_currency).
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

  -- ── Settlement требует кэш-счёт. Cash-сторона всегда в валюте счёта.
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
    VALUES (p_cash_account_id, v_acc.branch_id, v_cash_delta, v_acc.currency, now())
    ON CONFLICT (account_id) DO UPDATE
      SET balance = account_balances.balance + v_cash_delta,
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

    -- ── Settlement profit (только для cross-currency settle) ──
    -- actual_rate = p_amount (cash) / close_amount  →  «1 close_cur = X cash_cur»
    -- expected_rate — то же измерение.
    --   settle_from_us: мы платим p_amount cash за close_amount долга.
    --     profit = (expected_rate - actual_rate) × close_amount
    --              (хочется actual < expected → мы дёшево «купили» свой долг)
    --   settle_to_us: партнёр платит p_amount cash за close_amount долга
    --     перед нами.
    --     profit = (actual_rate - expected_rate) × close_amount
    --              (хочется actual > expected → партнёр дал больше за единицу)
    -- В обоих случаях профит выражается в валюте cash (p_currency).
    IF v_saldo_cur <> v_cash_cur AND p_expected_rate IS NOT NULL
       AND p_expected_rate > 0 AND v_close_amount > 0 THEN
      v_actual_rate := p_amount / v_close_amount;
      v_settlement_profit := CASE p_kind
        WHEN 'settle_from_us' THEN (p_expected_rate - v_actual_rate) * v_close_amount
        WHEN 'settle_to_us'   THEN (v_actual_rate - p_expected_rate) * v_close_amount
        ELSE 0
      END;
    END IF;
  END IF;

  -- ── Двигаем saldo партнёра (в саlдо-валюте, может != cash) ──
  v_curr_saldo := COALESCE(
    (v_cp.saldo_by_currency->>v_saldo_cur)::double precision, 0);
  v_new_saldo := v_curr_saldo + v_saldo_delta;

  UPDATE counterparties
    SET saldo_by_currency = saldo_by_currency
        || jsonb_build_object(v_saldo_cur, v_new_saldo)
  WHERE id = p_counterparty_id;

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
$$;

DROP FUNCTION IF EXISTS public.record_counterparty_op(
  uuid, text, double precision, text, text, uuid, uuid, text, double precision);

CREATE OR REPLACE FUNCTION public.record_counterparty_op(
  p_counterparty_id uuid,
  p_kind text,
  p_amount double precision,
  p_currency text,
  p_description text DEFAULT NULL,
  p_cash_account_id uuid DEFAULT NULL,
  p_transfer_id uuid DEFAULT NULL,
  p_payout_method text DEFAULT NULL,
  p_exchange_rate double precision DEFAULT NULL,
  p_close_amount double precision DEFAULT NULL,
  p_close_currency text DEFAULT NULL,
  p_expected_rate double precision DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.record_counterparty_op(
    p_counterparty_id, p_kind, p_amount, p_currency, p_description,
    p_cash_account_id, p_transfer_id, p_payout_method, p_exchange_rate,
    p_close_amount, p_close_currency, p_expected_rate);
$$;

GRANT EXECUTE ON FUNCTION public.record_counterparty_op(
  uuid, text, double precision, text, text, uuid, uuid, text, double precision,
  double precision, text, double precision
) TO authenticated;


-- ─── 3. partner_profit_summary с settlement_profit ───────────
-- CREATE OR REPLACE не может менять RETURN type → нужен DROP перед.
DROP FUNCTION IF EXISTS private.partner_profit_summary(
  uuid, timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION private.partner_profit_summary(
  p_counterparty_id uuid,
  p_start timestamptz DEFAULT NULL,
  p_end   timestamptz DEFAULT NULL
) RETURNS TABLE (
  currency text,
  transfer_count bigint,
  total_volume double precision,
  spread_profit double precision,
  commission_profit double precision,
  settlement_profit double precision,
  first_at timestamptz,
  last_at  timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH base AS (
    SELECT
      t.id,
      t.currency,
      t.amount,
      COALESCE(t.spread_profit, 0) AS spread,
      t.created_at
    FROM transfers t
    WHERE t.via_counterparty_id = p_counterparty_id
      AND (p_start IS NULL OR t.created_at >= p_start)
      AND (p_end   IS NULL OR t.created_at <  p_end)
  ),
  comm AS (
    SELECT
      c.transfer_id,
      c.currency,
      SUM(c.amount) AS commission_total
    FROM commissions c
    WHERE c.transfer_id IN (SELECT id FROM base)
    GROUP BY c.transfer_id, c.currency
  ),
  -- Settlement profit агрегируется отдельно — это профит на расчётах,
  -- не на самих переводах. Группируем по cash-валюте settlement-а.
  settle AS (
    SELECT
      cpt.settlement_profit_currency AS currency,
      SUM(cpt.settlement_profit)     AS settle_total
    FROM counterparty_transactions cpt
    WHERE cpt.counterparty_id = p_counterparty_id
      AND cpt.settlement_profit IS NOT NULL
      AND cpt.settlement_profit_currency IS NOT NULL
      AND (p_start IS NULL OR cpt.created_at >= p_start)
      AND (p_end   IS NULL OR cpt.created_at <  p_end)
    GROUP BY cpt.settlement_profit_currency
  ),
  per_cur AS (
    SELECT
      b.currency,
      COUNT(*)::bigint AS transfer_count,
      SUM(b.amount) AS total_volume,
      SUM(b.spread) AS spread_profit,
      COALESCE(SUM(
        (SELECT commission_total FROM comm WHERE comm.transfer_id = b.id AND comm.currency = b.currency)
      ), 0) AS commission_profit,
      MIN(b.created_at) AS first_at,
      MAX(b.created_at) AS last_at
    FROM base b
    GROUP BY b.currency
  )
  SELECT
    COALESCE(p.currency, s.currency) AS currency,
    COALESCE(p.transfer_count, 0) AS transfer_count,
    COALESCE(p.total_volume, 0) AS total_volume,
    COALESCE(p.spread_profit, 0) AS spread_profit,
    COALESCE(p.commission_profit, 0) AS commission_profit,
    COALESCE(s.settle_total, 0) AS settlement_profit,
    p.first_at,
    p.last_at
  FROM per_cur p
  FULL OUTER JOIN settle s ON s.currency = p.currency
  ORDER BY COALESCE(p.total_volume, 0) DESC NULLS LAST;
$$;

DROP FUNCTION IF EXISTS public.partner_profit_summary(uuid, timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION public.partner_profit_summary(
  p_counterparty_id uuid,
  p_start timestamptz DEFAULT NULL,
  p_end   timestamptz DEFAULT NULL
) RETURNS TABLE (
  currency text,
  transfer_count bigint,
  total_volume double precision,
  spread_profit double precision,
  commission_profit double precision,
  settlement_profit double precision,
  first_at timestamptz,
  last_at  timestamptz
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.partner_profit_summary(p_counterparty_id, p_start, p_end);
$$;

GRANT EXECUTE ON FUNCTION public.partner_profit_summary(uuid, timestamptz, timestamptz)
  TO authenticated;


-- ─── 4. counterparty_tx_detail с settlement-полями ───────────
DROP FUNCTION IF EXISTS private.counterparty_tx_detail(uuid, int);

CREATE OR REPLACE FUNCTION private.counterparty_tx_detail(
  p_counterparty_id uuid,
  p_limit int DEFAULT 100
) RETURNS TABLE (
  id uuid,
  kind text,
  amount double precision,
  currency text,
  description text,
  created_at timestamptz,
  transfer_id uuid,
  transaction_code text,
  payout_method text,
  buy_rate double precision,
  sell_rate double precision,
  base_currency text,
  spread_profit double precision,
  transfer_amount double precision,
  transfer_currency text,
  via_counterparty boolean,
  closes_amount double precision,
  closes_currency text,
  expected_rate double precision,
  settlement_profit double precision,
  settlement_profit_currency text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    cpt.id,
    cpt.kind,
    cpt.amount,
    cpt.currency,
    cpt.description,
    cpt.created_at,
    cpt.transfer_id,
    t.transaction_code,
    cpt.payout_method,
    t.buy_rate,
    t.sell_rate,
    t.base_currency,
    t.spread_profit,
    t.amount AS transfer_amount,
    t.currency AS transfer_currency,
    (t.via_counterparty_id IS NOT NULL) AS via_counterparty,
    cpt.closes_amount,
    cpt.closes_currency,
    cpt.expected_rate,
    cpt.settlement_profit,
    cpt.settlement_profit_currency
  FROM counterparty_transactions cpt
  LEFT JOIN transfers t ON t.id = cpt.transfer_id
  WHERE cpt.counterparty_id = p_counterparty_id
  ORDER BY cpt.created_at DESC
  LIMIT p_limit;
$$;

DROP FUNCTION IF EXISTS public.counterparty_tx_detail(uuid, int);

CREATE OR REPLACE FUNCTION public.counterparty_tx_detail(
  p_counterparty_id uuid,
  p_limit int DEFAULT 100
) RETURNS TABLE (
  id uuid,
  kind text,
  amount double precision,
  currency text,
  description text,
  created_at timestamptz,
  transfer_id uuid,
  transaction_code text,
  payout_method text,
  buy_rate double precision,
  sell_rate double precision,
  base_currency text,
  spread_profit double precision,
  transfer_amount double precision,
  transfer_currency text,
  via_counterparty boolean,
  closes_amount double precision,
  closes_currency text,
  expected_rate double precision,
  settlement_profit double precision,
  settlement_profit_currency text
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.counterparty_tx_detail(p_counterparty_id, p_limit);
$$;

GRANT EXECUTE ON FUNCTION public.counterparty_tx_detail(uuid, int)
  TO authenticated;

COMMIT;
