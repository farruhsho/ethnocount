-- ============================================================
-- 066: Сверка остатков (reconciliation / trial balance) — Этап 1.3
-- ============================================================
-- Аудит F1–F9 закрыл конкретные дыры, но не дал инструмента «деньги
-- сходятся». Нужна read-only сверка двух независимых денежных слоёв
-- против их первоисточника:
--
--   1) Касса филиала.  account_balances.balance (кэш) должен совпадать
--      с суммой проводок ledger_entries по каждому счёту. Пер-счётная
--      сверка уже есть в 031 (private.account_balances_audit_all);
--      здесь добавляем агрегат по филиалу/валюте (trial balance).
--
--   2) Сальдо партнёра.  counterparties.saldo_by_currency (JSONB) должно
--      совпадать с суммой counterparty_transactions, пересчитанной по
--      той же знак-конвенции, что и record_counterparty_op:
--          paid_for_us      → saldo -= закрытая_сумма
--          we_paid_for_them → saldo += закрытая_сумма
--          settle_to_us     → saldo -= закрытая_сумма
--          settle_from_us   → saldo += закрытая_сумма
--      «Закрытая сумма» = COALESCE(closes_amount, amount) в валюте
--      COALESCE(closes_currency, currency): при кросс-валютной операции
--      сальдо двигалось в closes_*, иначе в самой валюте операции.
--
-- Эти RPC НИЧЕГО не пишут и не блокируют — только возвращают расхождения
-- (delta). Они питают будущий экран аудита (Этап 3). Три денежных слоя
-- (касса / сальдо / клиентские балансы) не смешиваются: каждая сверка
-- работает строго внутри своего слоя.
--
-- Доступ: только creator/director (как admin_audit_balances из 031).
-- Идемпотентно: только CREATE OR REPLACE функций + GRANT, без новых
-- таблиц и без изменения схемы.
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1. Сверка кассы филиала: Σ ledger == Σ account_balances
--    Переиспользует частную аудит-функцию из 031 (та сама пересчитывает
--    каждый счёт по формуле credit−debit), здесь только агрегируем по
--    филиалу и валюте.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION private.reconcile_branch(
  p_branch_id uuid,
  p_currency  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_role    text;
  v_rows    jsonb;
  v_balanced boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  SELECT role::text INTO v_role FROM public.users WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('creator','director') THEN
    RAISE EXCEPTION 'Сверку остатков выполняет только Creator/Director';
  END IF;

  WITH agg AS (
    SELECT
      upper(a.currency)                  AS currency,
      round(SUM(a.cached)::numeric, 4)   AS account_balance,
      round(SUM(a.computed)::numeric, 4) AS ledger_sum,
      round(SUM(a.diff)::numeric, 4)     AS delta,
      COUNT(*)                           AS accounts,
      SUM(a.ledger_rows)                 AS ledger_rows
    FROM private.account_balances_audit_all() a
    WHERE a.branch_id = p_branch_id
      AND (p_currency IS NULL OR upper(a.currency) = upper(trim(p_currency)))
    GROUP BY upper(a.currency)
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'currency',       currency,
      'accountBalance', account_balance,
      'ledgerSum',      ledger_sum,
      'delta',          delta,
      'accounts',       accounts,
      'ledgerRows',     ledger_rows,
      'balanced',       (delta = 0)
    ) ORDER BY currency), '[]'::jsonb),
    COALESCE(bool_and(delta = 0), true)
  INTO v_rows, v_balanced
  FROM agg;

  RETURN jsonb_build_object(
    'branchId',   p_branch_id,
    'balanced',   v_balanced,
    'currencies', v_rows
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.reconcile_branch(
  p_branch_id uuid,
  p_currency  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.reconcile_branch(p_branch_id, p_currency); $$;

GRANT EXECUTE ON FUNCTION public.reconcile_branch(uuid, text) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 2. Сверка сальдо партнёра: saldo_by_currency == Σ операций
--    Знак и «закрытая сумма» строго как в private.record_counterparty_op
--    (056/058). closes_amount/closes_currency заполнены только при
--    кросс-валютной операции, иначе сальдо двигалось в самой валюте.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION private.reconcile_counterparty(
  p_counterparty_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_role     text;
  v_cp       counterparties%ROWTYPE;
  v_rows     jsonb;
  v_balanced boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  SELECT role::text INTO v_role FROM public.users WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('creator','director') THEN
    RAISE EXCEPTION 'Сверку сальдо выполняет только Creator/Director';
  END IF;

  SELECT * INTO v_cp FROM counterparties WHERE id = p_counterparty_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;

  WITH computed AS (
    SELECT
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
    WHERE t.counterparty_id = p_counterparty_id
    GROUP BY upper(COALESCE(t.closes_currency, t.currency))
  ),
  stored AS (
    SELECT upper(kv.key)                       AS currency,
           round((kv.value #>> '{}')::numeric, 4) AS stored
    FROM jsonb_each(v_cp.saldo_by_currency) kv
  ),
  merged AS (
    SELECT
      COALESCE(c.currency, s.currency) AS currency,
      COALESCE(s.stored, 0)            AS stored,
      COALESCE(c.computed, 0)          AS computed
    FROM computed c
    FULL OUTER JOIN stored s ON s.currency = c.currency
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'currency', currency,
      'stored',   stored,
      'computed', computed,
      'delta',    round((stored - computed)::numeric, 4),
      'balanced', (round((stored - computed)::numeric, 4) = 0)
    ) ORDER BY currency)
      FILTER (WHERE stored <> 0 OR computed <> 0), '[]'::jsonb),
    COALESCE(bool_and(round((stored - computed)::numeric, 4) = 0), true)
  INTO v_rows, v_balanced
  FROM merged;

  RETURN jsonb_build_object(
    'counterpartyId', p_counterparty_id,
    'name',           v_cp.name,
    'balanced',       v_balanced,
    'currencies',     v_rows
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.reconcile_counterparty(
  p_counterparty_id uuid
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.reconcile_counterparty(p_counterparty_id); $$;

GRANT EXECUTE ON FUNCTION public.reconcile_counterparty(uuid) TO authenticated;

-- ────────────────────────────────────────────────────────────
-- 3. Сводная сверка: пробегает по всем партнёрам и возвращает только
--    тех, у кого сальдо разошлось хоть в одной валюте. Точка входа для
--    экрана аудита (Этап 3.1): «покажи всё, что не сходится».
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION private.reconcile_counterparties_all()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_role    text;
  v_id      uuid;
  v_rec     jsonb;
  v_result  jsonb := '[]'::jsonb;
  v_checked integer := 0;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  SELECT role::text INTO v_role FROM public.users WHERE id = v_uid;
  IF v_role IS NULL OR v_role NOT IN ('creator','director') THEN
    RAISE EXCEPTION 'Сверку сальдо выполняет только Creator/Director';
  END IF;

  FOR v_id IN SELECT id FROM counterparties ORDER BY name LOOP
    v_checked := v_checked + 1;
    v_rec := private.reconcile_counterparty(v_id);
    IF (v_rec->>'balanced')::boolean IS DISTINCT FROM true THEN
      v_result := v_result || jsonb_build_array(v_rec);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'balanced',      (jsonb_array_length(v_result) = 0),
    'checked',       v_checked,
    'discrepancies', v_result
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.reconcile_counterparties_all()
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.reconcile_counterparties_all(); $$;

GRANT EXECUTE ON FUNCTION public.reconcile_counterparties_all() TO authenticated;

COMMIT;
