-- ============================================================
-- 037: Monthly partner profit timeseries
-- ============================================================
-- Возвращает помесячно: spread_profit + commission_profit + transfer_count
-- для построения графиков динамики во вкладке «Партнёры» аналитики.
--
-- Группировка: date_trunc('month', created_at), currency, branch_id.
-- Клиент далее аггрегирует/раскладывает как нужно (мульти-валютный
-- multi-line chart или один stacked bar).
--
-- p_partner_only=true ограничивает только партнёрскими переводами
-- (via_counterparty_id IS NOT NULL). По умолчанию false — для общей
-- аналитики прибыли по всем переводам.
--
-- Идемпотентно — CREATE OR REPLACE.
-- ============================================================

BEGIN;

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
      AND t.status NOT IN ('cancelled', 'rejected')
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

CREATE OR REPLACE FUNCTION public.partner_profit_monthly(
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
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.partner_profit_monthly(
    p_start, p_end, p_partner_only, p_counterparty_id);
$$;

GRANT EXECUTE ON FUNCTION public.partner_profit_monthly(
  timestamptz, timestamptz, boolean, uuid
) TO authenticated;

COMMIT;
