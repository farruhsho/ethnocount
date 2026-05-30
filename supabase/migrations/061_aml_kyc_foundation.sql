-- ============================================================
-- 061: Базовый AML/KYC-контур (F4)
-- ============================================================
-- Аудит: схема переводов/хавалы не имеет НИКАКИХ AML/KYC-проверок.
-- Нет порогов идентификации, нет контроля скорости (velocity) по
-- отправителю/получателю, нет журнала подозрительных операций.
-- Это прямой комплаенс-риск.
--
-- Решение — НЕблокирующий контур (WARN-only), чтобы не сломать уже
-- работающие денежные потоки. Скрин ничего не блокирует и в БД не
-- пишет; оператор сам решает, фиксировать ли флаг.
--
--   • aml_settings — единственная строка с порогами по валютам
--       (JSONB {ВАЛЮТА: число}):
--         id_required_by_currency      — выше суммы нужен документ
--         single_tx_review_by_currency — крупная разовая операция
--         daily_limit_by_currency      — суточный оборот на субъекта
--         monthly_limit_by_currency    — месячный оборот на субъекта
--   • aml_flags    — журнал срабатываний (open / reviewed / cleared)
--   • aml_screen(...)        — read-only скрин: суммирует оборот по
--       телефону субъекта и возвращает предупреждения
--   • aml_record_flag(...)   — фиксация флага (любой authenticated)
--   • aml_flags_list(...)    — лента флагов
--   • aml_resolve_flag(...)  — закрытие флага (creator/director)
--   • aml_get_settings() / aml_update_settings(...) — чтение/правка
--       порогов (правка только creator/director)
--
-- Денежные слои (saldo / касса / ledger) НЕ трогаются.
-- Идемпотентно: CREATE TABLE IF NOT EXISTS, DROP+CREATE функций.
-- ============================================================

BEGIN;

-- ─── 1. Таблицы ──────────────────────────────────────────────
-- Настройки: гарантированно одна строка (boolean PK = true).
CREATE TABLE IF NOT EXISTS public.aml_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  id_required_by_currency      jsonb NOT NULL DEFAULT '{}'::jsonb,
  single_tx_review_by_currency jsonb NOT NULL DEFAULT '{}'::jsonb,
  daily_limit_by_currency      jsonb NOT NULL DEFAULT '{}'::jsonb,
  monthly_limit_by_currency    jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid REFERENCES auth.users(id)
);
INSERT INTO public.aml_settings (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.aml_flags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id     uuid REFERENCES public.transfers(id) ON DELETE SET NULL,
  counterparty_id uuid REFERENCES public.counterparties(id) ON DELETE SET NULL,
  subject_phone text,
  subject_name  text,
  flag_type text NOT NULL,
  severity  text NOT NULL DEFAULT 'medium' CHECK (severity IN ('low','medium','high')),
  currency  text,
  amount    numeric,
  details   jsonb NOT NULL DEFAULT '{}'::jsonb,
  status    text NOT NULL DEFAULT 'open' CHECK (status IN ('open','reviewed','cleared')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid REFERENCES auth.users(id),
  resolved_at timestamptz,
  resolved_by uuid REFERENCES auth.users(id),
  resolution_note text
);
CREATE INDEX IF NOT EXISTS idx_aml_flags_status
  ON public.aml_flags (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_aml_flags_phone
  ON public.aml_flags (subject_phone);
CREATE INDEX IF NOT EXISTS idx_aml_flags_transfer
  ON public.aml_flags (transfer_id);

-- ─── 2. RLS ──────────────────────────────────────────────────
-- Чтение — любой authenticated. Запись — только через SECURITY
-- DEFINER RPC (они обходят RLS), поэтому INSERT/UPDATE-политик нет.
ALTER TABLE public.aml_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.aml_flags    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS aml_settings_select ON public.aml_settings;
CREATE POLICY aml_settings_select ON public.aml_settings
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS aml_flags_select ON public.aml_flags;
CREATE POLICY aml_flags_select ON public.aml_flags
  FOR SELECT TO authenticated USING (true);

-- ─── 3. Хелпер санитизации карты {валюта: число} ─────────────
-- Оставляет только положительные числа, ключи в upper-case.
-- NULL → NULL (не менять). '{}' → '{}' (очистить).
CREATE OR REPLACE FUNCTION private.aml_sanitize_currency_map(p_map jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_clean jsonb := '{}'::jsonb;
  v_key text;
  v_val jsonb;
  v_num numeric;
BEGIN
  IF p_map IS NULL THEN RETURN NULL; END IF;
  IF jsonb_typeof(p_map) <> 'object' THEN
    RAISE EXCEPTION 'Ожидался JSON-объект {валюта: число}';
  END IF;
  FOR v_key, v_val IN SELECT * FROM jsonb_each(p_map) LOOP
    BEGIN
      v_num := (v_val #>> '{}')::numeric;
    EXCEPTION WHEN others THEN
      v_num := NULL;
    END;
    IF v_num IS NOT NULL AND v_num > 0 THEN
      v_clean := v_clean || jsonb_build_object(upper(trim(v_key)), round(v_num, 4));
    END IF;
  END LOOP;
  RETURN v_clean;
END;
$$;

-- ─── 4. Чтение / правка порогов ──────────────────────────────
CREATE OR REPLACE FUNCTION private.aml_get_settings()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'idRequiredByCurrency',     s.id_required_by_currency,
    'singleTxReviewByCurrency', s.single_tx_review_by_currency,
    'dailyLimitByCurrency',     s.daily_limit_by_currency,
    'monthlyLimitByCurrency',   s.monthly_limit_by_currency,
    'updatedAt', s.updated_at
  )
  FROM aml_settings s WHERE s.id = true;
$$;

CREATE OR REPLACE FUNCTION public.aml_get_settings()
RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.aml_get_settings(); $$;

GRANT EXECUTE ON FUNCTION public.aml_get_settings() TO authenticated;

CREATE OR REPLACE FUNCTION private.aml_update_settings(
  p_id_required_by_currency      jsonb DEFAULT NULL,
  p_single_tx_review_by_currency jsonb DEFAULT NULL,
  p_daily_limit_by_currency      jsonb DEFAULT NULL,
  p_monthly_limit_by_currency    jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  SELECT role::text INTO v_role FROM public.users WHERE id = v_uid;
  IF v_role NOT IN ('creator','director') THEN
    RAISE EXCEPTION 'Пороги AML меняет только Creator/Director';
  END IF;

  UPDATE aml_settings SET
    id_required_by_currency =
      COALESCE(private.aml_sanitize_currency_map(p_id_required_by_currency),
               id_required_by_currency),
    single_tx_review_by_currency =
      COALESCE(private.aml_sanitize_currency_map(p_single_tx_review_by_currency),
               single_tx_review_by_currency),
    daily_limit_by_currency =
      COALESCE(private.aml_sanitize_currency_map(p_daily_limit_by_currency),
               daily_limit_by_currency),
    monthly_limit_by_currency =
      COALESCE(private.aml_sanitize_currency_map(p_monthly_limit_by_currency),
               monthly_limit_by_currency),
    updated_at = now(),
    updated_by = v_uid
  WHERE id = true;

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.aml_update_settings(
  p_id_required_by_currency      jsonb DEFAULT NULL,
  p_single_tx_review_by_currency jsonb DEFAULT NULL,
  p_daily_limit_by_currency      jsonb DEFAULT NULL,
  p_monthly_limit_by_currency    jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.aml_update_settings(
    p_id_required_by_currency, p_single_tx_review_by_currency,
    p_daily_limit_by_currency, p_monthly_limit_by_currency
  );
$$;

GRANT EXECUTE ON FUNCTION public.aml_update_settings(jsonb, jsonb, jsonb, jsonb)
  TO authenticated;

-- ─── 5. Скрин (read-only, ничего не блокирует) ───────────────
-- Суммирует оборот субъекта по телефону (как отправитель ИЛИ
-- получатель) в той же валюте за окна 1 день / 30 дней и сверяет
-- с порогами. Текущая сумма p_amount учитывается в velocity.
CREATE OR REPLACE FUNCTION private.aml_screen(
  p_subject_phone text,
  p_amount   numeric DEFAULT NULL,
  p_currency text    DEFAULT NULL,
  p_has_id   boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_phone text;
  v_cur text := upper(NULLIF(trim(p_currency), ''));
  v_s aml_settings%ROWTYPE;
  v_daily   numeric := 0;
  v_monthly numeric := 0;
  v_id_thr      numeric;
  v_review_thr  numeric;
  v_daily_thr   numeric;
  v_monthly_thr numeric;
  v_amount numeric := COALESCE(p_amount, 0);
  v_warnings jsonb := '[]'::jsonb;
  v_requires_id  boolean := false;
  v_large        boolean := false;
  v_over_daily   boolean := false;
  v_over_monthly boolean := false;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT * INTO v_s FROM aml_settings WHERE id = true;
  v_phone := private.normalize_phone(p_subject_phone);

  IF v_cur IS NOT NULL THEN
    v_id_thr      := NULLIF(v_s.id_required_by_currency->>v_cur, '')::numeric;
    v_review_thr  := NULLIF(v_s.single_tx_review_by_currency->>v_cur, '')::numeric;
    v_daily_thr   := NULLIF(v_s.daily_limit_by_currency->>v_cur, '')::numeric;
    v_monthly_thr := NULLIF(v_s.monthly_limit_by_currency->>v_cur, '')::numeric;
  END IF;

  IF v_phone IS NOT NULL AND v_phone <> '' AND v_cur IS NOT NULL THEN
    SELECT
      COALESCE(SUM(t.amount) FILTER (WHERE t.created_at >= now() - interval '1 day'), 0),
      COALESCE(SUM(t.amount) FILTER (WHERE t.created_at >= now() - interval '30 days'), 0)
    INTO v_daily, v_monthly
    FROM transfers t
    WHERE upper(t.currency) = v_cur
      AND (
        private.normalize_phone(t.sender_phone)   = v_phone
        OR private.normalize_phone(t.receiver_phone) = v_phone
      );
  END IF;

  -- Порог идентификации
  IF v_id_thr IS NOT NULL AND v_id_thr > 0 AND v_amount >= v_id_thr THEN
    v_requires_id := true;
    IF p_has_id IS NOT NULL AND NOT p_has_id THEN
      v_warnings := v_warnings || to_jsonb(format(
        'Сумма %s %s ≥ порога идентификации %s — нужен документ субъекта',
        round(v_amount, 2), v_cur, round(v_id_thr, 2)));
    END IF;
  END IF;

  -- Крупная разовая операция
  IF v_review_thr IS NOT NULL AND v_review_thr > 0 AND v_amount >= v_review_thr THEN
    v_large := true;
    v_warnings := v_warnings || to_jsonb(format(
      'Крупная разовая операция: %s %s ≥ %s — нужна проверка',
      round(v_amount, 2), v_cur, round(v_review_thr, 2)));
  END IF;

  -- Суточный оборот субъекта (с учётом текущей суммы)
  IF v_daily_thr IS NOT NULL AND v_daily_thr > 0
     AND (v_daily + v_amount) > v_daily_thr + 1e-6 THEN
    v_over_daily := true;
    v_warnings := v_warnings || to_jsonb(format(
      'Превышен суточный лимит субъекта: %s + %s > %s %s',
      round(v_daily, 2), round(v_amount, 2), round(v_daily_thr, 2), v_cur));
  END IF;

  -- Месячный оборот субъекта
  IF v_monthly_thr IS NOT NULL AND v_monthly_thr > 0
     AND (v_monthly + v_amount) > v_monthly_thr + 1e-6 THEN
    v_over_monthly := true;
    v_warnings := v_warnings || to_jsonb(format(
      'Превышен месячный лимит субъекта: %s + %s > %s %s',
      round(v_monthly, 2), round(v_amount, 2), round(v_monthly_thr, 2), v_cur));
  END IF;

  RETURN jsonb_build_object(
    'subjectPhone', v_phone,
    'currency',     v_cur,
    'amount',       v_amount,
    'dailyTotal',   round(v_daily, 4),
    'monthlyTotal', round(v_monthly, 4),
    'requiresId',   v_requires_id,
    'largeAmount',  v_large,
    'overDaily',    v_over_daily,
    'overMonthly',  v_over_monthly,
    'flagged',      (jsonb_array_length(v_warnings) > 0),
    'warnings',     v_warnings
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.aml_screen(
  p_subject_phone text,
  p_amount   numeric DEFAULT NULL,
  p_currency text    DEFAULT NULL,
  p_has_id   boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.aml_screen(p_subject_phone, p_amount, p_currency, p_has_id);
$$;

GRANT EXECUTE ON FUNCTION public.aml_screen(text, numeric, text, boolean)
  TO authenticated;

-- ─── 6. Фиксация флага ───────────────────────────────────────
CREATE OR REPLACE FUNCTION private.aml_record_flag(
  p_flag_type text,
  p_subject_phone text DEFAULT NULL,
  p_subject_name  text DEFAULT NULL,
  p_transfer_id   uuid DEFAULT NULL,
  p_counterparty_id uuid DEFAULT NULL,
  p_currency text    DEFAULT NULL,
  p_amount   numeric DEFAULT NULL,
  p_severity text    DEFAULT 'medium',
  p_details  jsonb   DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id uuid;
  v_sev text := lower(COALESCE(NULLIF(trim(p_severity), ''), 'medium'));
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  IF p_flag_type IS NULL OR length(trim(p_flag_type)) = 0 THEN
    RAISE EXCEPTION 'flag_type обязателен';
  END IF;
  IF v_sev NOT IN ('low','medium','high') THEN v_sev := 'medium'; END IF;

  INSERT INTO aml_flags
    (transfer_id, counterparty_id, subject_phone, subject_name, flag_type,
     severity, currency, amount, details, created_by)
  VALUES
    (p_transfer_id, p_counterparty_id,
     NULLIF(private.normalize_phone(p_subject_phone), ''),
     NULLIF(trim(p_subject_name), ''),
     trim(p_flag_type), v_sev,
     upper(NULLIF(trim(p_currency), '')),
     p_amount,
     COALESCE(p_details, '{}'::jsonb), v_uid)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'flagId', v_id::text);
END;
$$;

CREATE OR REPLACE FUNCTION public.aml_record_flag(
  p_flag_type text,
  p_subject_phone text DEFAULT NULL,
  p_subject_name  text DEFAULT NULL,
  p_transfer_id   uuid DEFAULT NULL,
  p_counterparty_id uuid DEFAULT NULL,
  p_currency text    DEFAULT NULL,
  p_amount   numeric DEFAULT NULL,
  p_severity text    DEFAULT 'medium',
  p_details  jsonb   DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.aml_record_flag(
    p_flag_type, p_subject_phone, p_subject_name, p_transfer_id,
    p_counterparty_id, p_currency, p_amount, p_severity, p_details
  );
$$;

GRANT EXECUTE ON FUNCTION public.aml_record_flag(
  text, text, text, uuid, uuid, text, numeric, text, jsonb
) TO authenticated;

-- ─── 7. Лента флагов ─────────────────────────────────────────
DROP FUNCTION IF EXISTS public.aml_flags_list(text, integer);
DROP FUNCTION IF EXISTS private.aml_flags_list(text, integer);

CREATE FUNCTION private.aml_flags_list(
  p_status text DEFAULT NULL,
  p_limit  integer DEFAULT 100
) RETURNS TABLE (
  id uuid,
  transfer_id uuid,
  counterparty_id uuid,
  subject_phone text,
  subject_name text,
  flag_type text,
  severity text,
  currency text,
  amount numeric,
  details jsonb,
  status text,
  created_at timestamptz,
  created_by uuid,
  resolved_at timestamptz,
  resolved_by uuid,
  resolution_note text,
  transaction_code text,
  counterparty_name text
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    f.id, f.transfer_id, f.counterparty_id, f.subject_phone, f.subject_name,
    f.flag_type, f.severity, f.currency, f.amount, f.details, f.status,
    f.created_at, f.created_by, f.resolved_at, f.resolved_by, f.resolution_note,
    t.transaction_code, cp.name
  FROM aml_flags f
  LEFT JOIN transfers t      ON t.id  = f.transfer_id
  LEFT JOIN counterparties cp ON cp.id = f.counterparty_id
  WHERE (p_status IS NULL OR f.status = p_status)
  ORDER BY f.created_at DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 100), 500));
$$;

CREATE FUNCTION public.aml_flags_list(
  p_status text DEFAULT NULL,
  p_limit  integer DEFAULT 100
) RETURNS TABLE (
  id uuid,
  transfer_id uuid,
  counterparty_id uuid,
  subject_phone text,
  subject_name text,
  flag_type text,
  severity text,
  currency text,
  amount numeric,
  details jsonb,
  status text,
  created_at timestamptz,
  created_by uuid,
  resolved_at timestamptz,
  resolved_by uuid,
  resolution_note text,
  transaction_code text,
  counterparty_name text
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.aml_flags_list(p_status, p_limit);
$$;

GRANT EXECUTE ON FUNCTION public.aml_flags_list(text, integer) TO authenticated;

-- ─── 8. Закрытие флага (creator/director) ────────────────────
CREATE OR REPLACE FUNCTION private.aml_resolve_flag(
  p_flag_id uuid,
  p_status  text,
  p_note    text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_status text := lower(trim(p_status));
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  SELECT role::text INTO v_role FROM public.users WHERE id = v_uid;
  IF v_role NOT IN ('creator','director') THEN
    RAISE EXCEPTION 'Закрывать AML-флаги может только Creator/Director';
  END IF;
  IF v_status NOT IN ('open','reviewed','cleared') THEN
    RAISE EXCEPTION 'Недопустимый статус: %', p_status;
  END IF;

  UPDATE aml_flags SET
    status = v_status,
    resolved_at = CASE WHEN v_status = 'open' THEN NULL ELSE now() END,
    resolved_by = CASE WHEN v_status = 'open' THEN NULL ELSE v_uid END,
    resolution_note = COALESCE(NULLIF(trim(p_note), ''), resolution_note)
  WHERE id = p_flag_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Флаг не найден'; END IF;

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.aml_resolve_flag(
  p_flag_id uuid,
  p_status  text,
  p_note    text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.aml_resolve_flag(p_flag_id, p_status, p_note);
$$;

GRANT EXECUTE ON FUNCTION public.aml_resolve_flag(uuid, text, text)
  TO authenticated;

COMMIT;
