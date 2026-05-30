-- ============================================================
-- 045: counterparty_tx_detail с receiver_* колонками
-- ============================================================
-- P1.3: в истории операций партнёра показывать ФИО и телефон получателя.
-- Раньше эти данные были только в description (текстом).
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.counterparty_tx_detail(uuid, int);
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
  settlement_profit_currency text,
  receiver_name text,
  receiver_phone text,
  receiver_info text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    cpt.id, cpt.kind, cpt.amount, cpt.currency,
    cpt.description, cpt.created_at, cpt.transfer_id,
    t.transaction_code, cpt.payout_method,
    t.buy_rate, t.sell_rate, t.base_currency, t.spread_profit,
    t.amount AS transfer_amount, t.currency AS transfer_currency,
    (t.via_counterparty_id IS NOT NULL) AS via_counterparty,
    cpt.closes_amount, cpt.closes_currency, cpt.expected_rate,
    cpt.settlement_profit, cpt.settlement_profit_currency,
    t.receiver_name, t.receiver_phone, t.receiver_info
  FROM counterparty_transactions cpt
  LEFT JOIN transfers t ON t.id = cpt.transfer_id
  WHERE cpt.counterparty_id = p_counterparty_id
  ORDER BY cpt.created_at DESC
  LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION public.counterparty_tx_detail(
  p_counterparty_id uuid,
  p_limit int DEFAULT 100
) RETURNS TABLE (
  id uuid, kind text, amount double precision, currency text,
  description text, created_at timestamptz, transfer_id uuid,
  transaction_code text, payout_method text,
  buy_rate double precision, sell_rate double precision,
  base_currency text, spread_profit double precision,
  transfer_amount double precision, transfer_currency text,
  via_counterparty boolean,
  closes_amount double precision, closes_currency text,
  expected_rate double precision,
  settlement_profit double precision, settlement_profit_currency text,
  receiver_name text, receiver_phone text, receiver_info text
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.counterparty_tx_detail(p_counterparty_id, p_limit);
$$;

GRANT EXECUTE ON FUNCTION public.counterparty_tx_detail(uuid, int)
  TO authenticated;

COMMIT;
