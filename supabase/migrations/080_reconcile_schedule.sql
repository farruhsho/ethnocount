-- ============================================================
-- 080: Расписание и единая точка входа сверки остатков — Этап 1.3 (запуск)
-- ============================================================
-- 066 дал три read-only RPC сверки (reconcile_branch /
-- reconcile_counterparty / reconcile_counterparties_all), но НИЧЕГО их
-- не вызывает. Дрифт между кэшем (account_balances / saldo_by_currency)
-- и первоисточником (ledger_entries / counterparty_transactions) никем
-- не отслеживается до тех пор, пока кто-то вручную не откроет экран.
--
-- Эта миграция:
--   1) Заводит таблицу public.reconciliation_alerts — журнал
--      обнаруженных ненулевых расхождений (дрифтов).
--   2) Добавляет единую SECURITY DEFINER точку входа
--      private.run_reconciliation(): пробегает по ВСЕМ филиалам
--      (reconcile_branch) и по всем партнёрам
--      (reconcile_counterparties_all), собирает любой ненулевой delta в
--      reconciliation_alerts и возвращает сводный jsonb.
--   3) public.run_reconciliation() — обёртка, GRANT authenticated, но
--      внутри ОГРАНИЧИВАЕТ выполнение creator/director.
--   4) Пытается запланировать ежедневный прогон через pg_cron, ЕСЛИ
--      расширение установлено. Если pg_cron отсутствует — миграция НЕ
--      падает, а печатает NOTICE. Включение pg_cron делается в Supabase
--      dashboard (Database → Extensions → pg_cron), после чего
--      достаточно один раз выполнить блок cron.schedule из конца файла.
--
-- ВАЖНО про авторизацию под cron: задание pg_cron исполняется без
-- auth-контекста (auth.uid() IS NULL), поэтому private.run_reconciliation
-- НЕ переиспользует role-gated private.reconcile_* (они бы упали на
-- проверке роли), а пересчитывает дрифт самостоятельно теми же запросами.
-- Интерактивный доступ гейтится в public-обёртке.
--
-- Read-only по бизнес-данным: пишем ТОЛЬКО в reconciliation_alerts (свой
-- журнал), деньги/сальдо не трогаем. Идемпотентно. BEGIN/COMMIT.
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1. Журнал расхождений
--    scope:    'branch' | 'counterparty'
--    scope_id: branches.id | counterparties.id
--    kind:     валюта, в которой обнаружен дрифт (напр. 'USD')
--    expected: что ДОЛЖНО быть (первоисточник: ledgerSum / computed)
--    actual:   что СЕЙЧАС в кэше (accountBalance / stored)
--    delta:    actual - expected (знак: насколько кэш «врёт»)
-- ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reconciliation_alerts (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  scope       text        NOT NULL CHECK (scope IN ('branch','counterparty')),
  scope_id    uuid        NOT NULL,
  kind        text        NOT NULL,
  expected    numeric     NOT NULL,
  actual      numeric     NOT NULL,
  delta       numeric     NOT NULL,
  detected_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_reconciliation_alerts_detected_at
  ON public.reconciliation_alerts (detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_reconciliation_alerts_scope
  ON public.reconciliation_alerts (scope, scope_id);

-- RLS: журнал читают только creator/director, пишет в него только
-- SECURITY DEFINER функция (которая обходит RLS под своим владельцем).
ALTER TABLE public.reconciliation_alerts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS reconciliation_alerts_read ON public.reconciliation_alerts;
CREATE POLICY reconciliation_alerts_read
  ON public.reconciliation_alerts
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid()
        AND u.role::text IN ('creator','director')
    )
  );

GRANT SELECT ON public.reconciliation_alerts TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 2. Единая точка входа сверки (SECURITY DEFINER, без role-гейта —
--    гейт живёт в public-обёртке; под cron auth-контекста нет).
--    Пишет ненулевые дрифты в reconciliation_alerts и возвращает summary.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION private.run_reconciliation()
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_run_at         timestamptz := now();
  v_branch_alerts  integer := 0;
  v_cp_alerts      integer := 0;
  v_branches_count integer := 0;
  v_cp_count       integer := 0;
BEGIN
  -- ── Касса филиалов: account_balances.balance vs Σ ledger ──
  -- Пересчёт идентичен private.reconcile_branch (066): берём агрегат из
  -- private.account_balances_audit_all() по филиалу/валюте. expected =
  -- первоисточник (ledgerSum), actual = кэш (accountBalance).
  WITH agg AS (
    SELECT
      a.branch_id                        AS branch_id,
      upper(a.currency)                  AS currency,
      round(SUM(a.cached)::numeric, 4)   AS account_balance,
      round(SUM(a.computed)::numeric, 4) AS ledger_sum,
      round(SUM(a.diff)::numeric, 4)     AS delta
    FROM private.account_balances_audit_all() a
    GROUP BY a.branch_id, upper(a.currency)
  ),
  ins AS (
    INSERT INTO public.reconciliation_alerts
      (scope, scope_id, kind, expected, actual, delta, detected_at)
    SELECT 'branch', agg.branch_id, agg.currency,
           agg.ledger_sum, agg.account_balance, agg.delta, v_run_at
    FROM agg
    WHERE agg.delta <> 0
    RETURNING 1
  )
  SELECT count(*) INTO v_branch_alerts FROM ins;

  SELECT count(DISTINCT id) INTO v_branches_count FROM public.branches;

  -- ── Сальдо партнёров: saldo_by_currency vs Σ операций ──
  -- Знак и «закрытая сумма» строго как в private.record_counterparty_op
  -- и private.reconcile_counterparty (066). expected = computed
  -- (первоисточник), actual = stored (кэш saldo_by_currency).
  WITH computed AS (
    SELECT
      t.counterparty_id                              AS counterparty_id,
      upper(COALESCE(t.closes_currency, t.currency)) AS currency,
      round(SUM(
        CASE t.kind
          WHEN 'paid_for_us'      THEN -COALESCE(t.closes_amount, t.amount)
          WHEN 'we_paid_for_them' THEN  COALESCE(t.closes_amount, t.amount)
          WHEN 'settle_to_us'     THEN -COALESCE(t.closes_amount, t.amount)
          WHEN 'settle_from_us'   THEN  COALESCE(t.closes_amount, t.amount)
        END
      )::numeric, 4) AS computed
    FROM counterparty_transactions t
    GROUP BY t.counterparty_id, upper(COALESCE(t.closes_currency, t.currency))
  ),
  stored AS (
    SELECT c.id                                  AS counterparty_id,
           upper(kv.key)                         AS currency,
           round((kv.value #>> '{}')::numeric, 4) AS stored
    FROM counterparties c
    CROSS JOIN LATERAL jsonb_each(c.saldo_by_currency) kv
  ),
  merged AS (
    SELECT
      COALESCE(c.counterparty_id, s.counterparty_id) AS counterparty_id,
      COALESCE(c.currency, s.currency)               AS currency,
      COALESCE(s.stored, 0)                          AS stored,
      COALESCE(c.computed, 0)                        AS computed
    FROM computed c
    FULL OUTER JOIN stored s
      ON s.counterparty_id = c.counterparty_id
     AND s.currency        = c.currency
  ),
  ins AS (
    INSERT INTO public.reconciliation_alerts
      (scope, scope_id, kind, expected, actual, delta, detected_at)
    SELECT 'counterparty', m.counterparty_id, m.currency,
           m.computed, m.stored,
           round((m.stored - m.computed)::numeric, 4), v_run_at
    FROM merged m
    WHERE round((m.stored - m.computed)::numeric, 4) <> 0
    RETURNING 1
  )
  SELECT count(*) INTO v_cp_alerts FROM ins;

  SELECT count(*) INTO v_cp_count FROM counterparties;

  RETURN jsonb_build_object(
    'runAt',             v_run_at,
    'balanced',          (v_branch_alerts = 0 AND v_cp_alerts = 0),
    'branchesChecked',   v_branches_count,
    'branchAlerts',      v_branch_alerts,
    'counterpartiesChecked', v_cp_count,
    'counterpartyAlerts', v_cp_alerts,
    'totalAlerts',       (v_branch_alerts + v_cp_alerts)
  );
END;
$$;

-- Публичная обёртка: GRANT authenticated, но внутри — только creator/director.
CREATE OR REPLACE FUNCTION public.run_reconciliation()
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_role text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  SELECT role::text INTO v_role FROM public.users WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('creator','director') THEN
    RAISE EXCEPTION 'Сверку остатков выполняет только Creator/Director';
  END IF;
  RETURN private.run_reconciliation();
END;
$$;

GRANT EXECUTE ON FUNCTION public.run_reconciliation() TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 3. Планирование через pg_cron — мягкое, без падения миграции.
--    Если расширения нет — печатаем NOTICE и продолжаем. Ежедневный
--    прогон в 02:00 UTC вызывает private.run_reconciliation() напрямую
--    (под cron нет auth-контекста, поэтому именно private-вариант).
-- ────────────────────────────────────────────────────────────
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Снимаем прежнее задание с тем же именем (идемпотентность), если есть.
    BEGIN
      PERFORM cron.unschedule('ethnocount_daily_reconciliation');
    EXCEPTION WHEN OTHERS THEN
      -- задания ещё нет — это нормально
      NULL;
    END;

    PERFORM cron.schedule(
      'ethnocount_daily_reconciliation',
      '0 2 * * *',
      $job$ SELECT private.run_reconciliation(); $job$
    );
    RAISE NOTICE 'pg_cron: запланирована ежедневная сверка (ethnocount_daily_reconciliation, 02:00 UTC)';
  ELSE
    RAISE NOTICE 'pg_cron не установлен — авто-сверка НЕ запланирована. '
                 'Включите pg_cron в Supabase dashboard (Database → Extensions), '
                 'затем выполните блок cron.schedule из конца 080_reconcile_schedule.sql.';
  END IF;
END;
$cron$;

COMMIT;

-- ============================================================
-- РУЧНОЕ ВКЛЮЧЕНИЕ РАСПИСАНИЯ (после включения pg_cron в dashboard):
--
--   SELECT cron.schedule(
--     'ethnocount_daily_reconciliation',
--     '0 2 * * *',
--     $$ SELECT private.run_reconciliation(); $$
--   );
--
-- Снять расписание:
--   SELECT cron.unschedule('ethnocount_daily_reconciliation');
-- ============================================================
