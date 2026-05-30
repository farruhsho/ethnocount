-- ============================================================
-- 050: commission profit breakdown by branch + currency + period
-- ============================================================
-- Раньше прибыль с комиссии можно было увидеть только в разрезе
-- партнёра (partner_profit_summary, миграция 036). Не было простого
-- ответа на вопрос «сколько каждый филиал заработал за месяц по
-- валютам».
--
-- Эта миграция добавляет два RPC:
--
--   public.commission_profit_by_branch(p_start, p_end, p_branch_ids)
--      RETURNS TABLE(branch_id, branch_code, branch_name,
--                    currency, transfer_count, total_commission)
--      — детальная разбивка: по каждому филиалу × валюта.
--      p_branch_ids фильтрует выдачу (NULL = все доступные —
--      RLS commissions_select оставлена `USING (true)` для creator;
--      бухгалтер передаёт свои assigned_branch_ids со стороны клиента).
--
--   public.commission_profit_totals(p_start, p_end, p_branch_ids)
--      RETURNS TABLE(currency, transfer_count, total_commission)
--      — суммы по валютам без разбивки на филиалы. Используется для
--      строки «Итого» в UI.
--
-- Период по created_at:
--   • p_start NULL → с начала времён
--   • p_end   NULL → до now()
--
-- Идемпотентно. CREATE OR REPLACE.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.commission_profit_by_branch(
  p_start      timestamptz DEFAULT NULL,
  p_end        timestamptz DEFAULT NULL,
  p_branch_ids uuid[] DEFAULT NULL
) RETURNS TABLE (
  branch_id        uuid,
  branch_code      text,
  branch_name      text,
  currency         text,
  transfer_count   bigint,
  total_commission double precision
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    c.branch_id,
    COALESCE(b.code, '—') AS branch_code,
    COALESCE(b.name, '—') AS branch_name,
    UPPER(c.currency) AS currency,
    COUNT(DISTINCT c.transfer_id) AS transfer_count,
    ROUND(SUM(c.amount)::numeric, 2)::double precision AS total_commission
  FROM public.commissions c
  LEFT JOIN public.branches b ON b.id = c.branch_id
  WHERE
    c.amount > 0
    AND (p_start IS NULL OR c.created_at >= p_start)
    AND (p_end   IS NULL OR c.created_at <  p_end)
    AND (p_branch_ids IS NULL
         OR c.branch_id = ANY(p_branch_ids))
  GROUP BY c.branch_id, b.code, b.name, UPPER(c.currency)
  ORDER BY COALESCE(b.name, '—'), UPPER(c.currency);
$$;

GRANT EXECUTE ON FUNCTION public.commission_profit_by_branch(
  timestamptz, timestamptz, uuid[]
) TO authenticated;


CREATE OR REPLACE FUNCTION public.commission_profit_totals(
  p_start      timestamptz DEFAULT NULL,
  p_end        timestamptz DEFAULT NULL,
  p_branch_ids uuid[] DEFAULT NULL
) RETURNS TABLE (
  currency         text,
  transfer_count   bigint,
  total_commission double precision
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    UPPER(c.currency) AS currency,
    COUNT(DISTINCT c.transfer_id) AS transfer_count,
    ROUND(SUM(c.amount)::numeric, 2)::double precision AS total_commission
  FROM public.commissions c
  WHERE
    c.amount > 0
    AND (p_start IS NULL OR c.created_at >= p_start)
    AND (p_end   IS NULL OR c.created_at <  p_end)
    AND (p_branch_ids IS NULL
         OR c.branch_id = ANY(p_branch_ids))
  GROUP BY UPPER(c.currency)
  ORDER BY UPPER(c.currency);
$$;

GRANT EXECUTE ON FUNCTION public.commission_profit_totals(
  timestamptz, timestamptz, uuid[]
) TO authenticated;

COMMIT;
