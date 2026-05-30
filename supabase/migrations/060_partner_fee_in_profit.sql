-- ============================================================
-- 060: Комиссия партнёра как расход в аналитике прибыли (F9)
-- ============================================================
-- counterparties.fee_percentage хранился «на будущее» и нигде не
-- учитывался. Партнёр берёт % за выплату нашим клиентам — это наш
-- РАСХОД, который съедает маржу. Раньше отчёт показывал только
-- валовую прибыль (спред + комиссия), завышая реальный результат.
--
-- Решение: расширяем partner_profit_summary тремя колонками:
--   • partner_fee_pct   — ставка партнёра (%), снимок из counterparties
--   • partner_fee_cost  — расход = объём переводов * pct / 100
--   • net_profit        — чистыми = спред + комиссия − partner_fee_cost
--
-- Это ЧИСТО аналитический расчёт: денежные слои (saldo / касса /
-- ledger) не трогаются. Settlement-профит по-прежнему отдельной
-- колонкой (он считается на этапе расчёта, не на переводе).
--
-- CREATE OR REPLACE не может менять RETURNS TABLE → DROP перед.
-- Идемпотентно.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS public.partner_profit_summary(uuid, timestamptz, timestamptz);
DROP FUNCTION IF EXISTS private.partner_profit_summary(uuid, timestamptz, timestamptz);

CREATE FUNCTION private.partner_profit_summary(
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
  partner_fee_pct double precision,
  partner_fee_cost double precision,
  net_profit double precision,
  first_at timestamptz,
  last_at  timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH feerate AS (
    SELECT COALESCE(fee_percentage, 0)::double precision AS pct
    FROM counterparties WHERE id = p_counterparty_id
  ),
  base AS (
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
    (SELECT pct FROM feerate) AS partner_fee_pct,
    round(
      (COALESCE(p.total_volume, 0) * (SELECT pct FROM feerate) / 100.0)::numeric, 4
    )::double precision AS partner_fee_cost,
    (
      COALESCE(p.spread_profit, 0) + COALESCE(p.commission_profit, 0)
      - round(
          (COALESCE(p.total_volume, 0) * (SELECT pct FROM feerate) / 100.0)::numeric, 4
        )::double precision
    ) AS net_profit,
    p.first_at,
    p.last_at
  FROM per_cur p
  FULL OUTER JOIN settle s ON s.currency = p.currency
  ORDER BY COALESCE(p.total_volume, 0) DESC NULLS LAST;
$$;

CREATE FUNCTION public.partner_profit_summary(
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
  partner_fee_pct double precision,
  partner_fee_cost double precision,
  net_profit double precision,
  first_at timestamptz,
  last_at  timestamptz
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.partner_profit_summary(p_counterparty_id, p_start, p_end);
$$;

GRANT EXECUTE ON FUNCTION public.partner_profit_summary(uuid, timestamptz, timestamptz)
  TO authenticated;

COMMIT;
