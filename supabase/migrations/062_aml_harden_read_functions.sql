-- ============================================================
-- 062: Хардненинг read-функций AML (F4, follow-up к 061)
-- ============================================================
-- Security advisor после 061:
--   1) private.aml_sanitize_currency_map — mutable search_path.
--   2) aml_get_settings() и aml_flags_list() — SECURITY DEFINER без
--      проверки auth.uid(). Они обходят RLS, а EXECUTE по умолчанию
--      есть и у роли anon → анонимный вызов мог бы прочитать пороги
--      и (что важнее) PII из журнала флагов (телефоны/имена).
--
-- Пишущие RPC (screen/record/update/resolve) уже проверяют auth.uid(),
-- здесь закрываем две читающие: добавляем guard auth.uid() IS NULL.
-- Сигнатуры не меняются → CREATE OR REPLACE, идемпотентно.
-- ============================================================

BEGIN;

-- 1) Фикс mutable search_path у хелпера.
CREATE OR REPLACE FUNCTION private.aml_sanitize_currency_map(p_map jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
SET search_path = public
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

-- 2) aml_get_settings: требуем аутентификацию.
CREATE OR REPLACE FUNCTION private.aml_get_settings()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  SELECT jsonb_build_object(
    'idRequiredByCurrency',     s.id_required_by_currency,
    'singleTxReviewByCurrency', s.single_tx_review_by_currency,
    'dailyLimitByCurrency',     s.daily_limit_by_currency,
    'monthlyLimitByCurrency',   s.monthly_limit_by_currency,
    'updatedAt', s.updated_at
  ) INTO v_res
  FROM aml_settings s WHERE s.id = true;
  RETURN v_res;
END;
$$;

-- 3) aml_flags_list: требуем аутентификацию (журнал содержит PII).
CREATE OR REPLACE FUNCTION private.aml_flags_list(
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
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;
  RETURN QUERY
  SELECT
    f.id, f.transfer_id, f.counterparty_id, f.subject_phone, f.subject_name,
    f.flag_type, f.severity, f.currency, f.amount, f.details, f.status,
    f.created_at, f.created_by, f.resolved_at, f.resolved_by, f.resolution_note,
    t.transaction_code, cp.name
  FROM aml_flags f
  LEFT JOIN transfers t       ON t.id  = f.transfer_id
  LEFT JOIN counterparties cp ON cp.id = f.counterparty_id
  WHERE (p_status IS NULL OR f.status = p_status)
  ORDER BY f.created_at DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 100), 500));
END;
$$;

COMMIT;
