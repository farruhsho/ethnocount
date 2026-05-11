-- ============================================================
-- 016: Supported currencies per branch
-- ============================================================
-- Цель: каждый филиал может ограничить список валют, которыми он реально
-- оперирует (Бишкек: KGS/USD/EUR/RUB; Москва: RUB/USD/EUR; и т.п.).
--
-- Правила:
--   * `branches.supported_currencies` — jsonb-массив ISO-кодов
--     (`["USD","EUR","RUB","KGS"]`).  NULL означает «без ограничения».
--   * `base_currency` остаётся обязательным; если задан supported_currencies,
--     base_currency должна быть в списке.
--   * RPC admin_create_branch / admin_update_branch принимают новый параметр
--     `p_supported_currencies text[]`.  Передача NULL — не менять.  Передача
--     пустого массива (`'{}'`) — сбросить (= «все валюты»).
-- ============================================================

-- 1. column ----------------------------------------------------
ALTER TABLE public.branches
  ADD COLUMN IF NOT EXISTS supported_currencies jsonb;

COMMENT ON COLUMN public.branches.supported_currencies IS
  'JSON-массив ISO-кодов валют, которыми оперирует филиал. NULL = все валюты.';

-- 2. helper: проверяем, что массив непустой и состоит из 3-letter ISO-кодов
CREATE OR REPLACE FUNCTION private.validate_currency_codes(p jsonb)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = public, pg_temp
AS $$
  SELECT p IS NULL OR (
    jsonb_typeof(p) = 'array'
    AND jsonb_array_length(p) > 0
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements_text(p) e
      WHERE length(e) <> 3 OR e <> upper(e)
    )
  )
$$;

ALTER TABLE public.branches
  DROP CONSTRAINT IF EXISTS branches_supported_currencies_valid;
ALTER TABLE public.branches
  ADD CONSTRAINT branches_supported_currencies_valid
  CHECK (private.validate_currency_codes(supported_currencies));

-- 3. update admin_create_branch / admin_update_branch -----------

DROP FUNCTION IF EXISTS public.admin_create_branch(text, text, text, text, text, text, int);
DROP FUNCTION IF EXISTS public.admin_update_branch(uuid, text, text, text, text, text, text, int, text);

CREATE OR REPLACE FUNCTION private.admin_create_branch(
  p_name text,
  p_code text,
  p_base_currency text DEFAULT 'USD',
  p_supported_currencies text[] DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_sort_order int DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id uuid;
  v_supported jsonb := NULL;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Требуется авторизация'; END IF;
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может создавать филиалы'; END IF;
  IF coalesce(trim(p_name), '') = '' THEN RAISE EXCEPTION 'Название филиала обязательно'; END IF;
  IF coalesce(trim(p_code), '') = '' THEN RAISE EXCEPTION 'Код филиала обязателен'; END IF;

  IF p_supported_currencies IS NOT NULL AND array_length(p_supported_currencies, 1) IS NOT NULL THEN
    v_supported := to_jsonb(p_supported_currencies);
    IF NOT private.validate_currency_codes(v_supported) THEN
      RAISE EXCEPTION 'Некорректный список валют: ожидаются 3-буквенные ISO-коды в верхнем регистре';
    END IF;
    IF NOT (v_supported ? coalesce(p_base_currency, 'USD')) THEN
      RAISE EXCEPTION 'Базовая валюта % должна входить в поддерживаемые валюты', p_base_currency;
    END IF;
  END IF;

  INSERT INTO public.branches (name, code, base_currency, supported_currencies,
                               address, phone, notes, sort_order, is_active)
  VALUES (trim(p_name), trim(p_code), coalesce(p_base_currency, 'USD'), v_supported,
          p_address, p_phone, p_notes, coalesce(p_sort_order, 0), true)
  RETURNING id INTO v_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('branch.created', 'branch', v_id::text, v_uid,
          jsonb_build_object(
            'name', p_name,
            'code', p_code,
            'baseCurrency', p_base_currency,
            'supportedCurrencies', v_supported
          ));

  RETURN jsonb_build_object('success', true, 'branchId', v_id::text);
END
$$;

CREATE OR REPLACE FUNCTION private.admin_update_branch(
  p_branch_id uuid,
  p_name text DEFAULT NULL,
  p_code text DEFAULT NULL,
  p_base_currency text DEFAULT NULL,
  p_supported_currencies text[] DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_sort_order int DEFAULT NULL,
  p_code_change_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_branch public.branches%ROWTYPE;
  v_changes jsonb := '{}'::jsonb;
  v_supported_new jsonb;
  v_apply_supported boolean := false;
  v_target_base text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Требуется авторизация'; END IF;
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может изменять филиалы'; END IF;

  SELECT * INTO v_branch FROM public.branches WHERE id = p_branch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Филиал не найден'; END IF;

  IF p_supported_currencies IS NOT NULL THEN
    v_apply_supported := true;
    IF array_length(p_supported_currencies, 1) IS NULL THEN
      -- Пустой массив -> сбрасываем (NULL = все валюты).
      v_supported_new := NULL;
    ELSE
      v_supported_new := to_jsonb(p_supported_currencies);
      IF NOT private.validate_currency_codes(v_supported_new) THEN
        RAISE EXCEPTION 'Некорректный список валют: ожидаются 3-буквенные ISO-коды в верхнем регистре';
      END IF;
      v_target_base := COALESCE(p_base_currency, v_branch.base_currency);
      IF NOT (v_supported_new ? v_target_base) THEN
        RAISE EXCEPTION 'Базовая валюта % должна входить в поддерживаемые валюты', v_target_base;
      END IF;
    END IF;
  END IF;

  IF p_code IS NOT NULL AND trim(p_code) <> v_branch.code THEN
    INSERT INTO public.branch_code_history (branch_id, old_code, new_code, changed_by, reason)
    VALUES (p_branch_id, v_branch.code, trim(p_code), v_uid, p_code_change_reason);
    v_changes := v_changes || jsonb_build_object('code', jsonb_build_object('from', v_branch.code, 'to', trim(p_code)));
  END IF;
  IF p_name IS NOT NULL AND trim(p_name) <> v_branch.name THEN
    v_changes := v_changes || jsonb_build_object('name', jsonb_build_object('from', v_branch.name, 'to', trim(p_name)));
  END IF;
  IF p_base_currency IS NOT NULL AND p_base_currency <> v_branch.base_currency THEN
    v_changes := v_changes || jsonb_build_object('baseCurrency', jsonb_build_object('from', v_branch.base_currency, 'to', p_base_currency));
  END IF;
  IF v_apply_supported AND v_supported_new IS DISTINCT FROM v_branch.supported_currencies THEN
    v_changes := v_changes || jsonb_build_object('supportedCurrencies',
      jsonb_build_object('from', v_branch.supported_currencies, 'to', v_supported_new));
  END IF;

  UPDATE public.branches SET
    name = COALESCE(NULLIF(trim(p_name), ''), name),
    code = COALESCE(NULLIF(trim(p_code), ''), code),
    base_currency = COALESCE(p_base_currency, base_currency),
    supported_currencies = CASE WHEN v_apply_supported THEN v_supported_new ELSE supported_currencies END,
    address = CASE WHEN p_address IS NULL THEN address ELSE NULLIF(trim(p_address), '') END,
    phone = CASE WHEN p_phone IS NULL THEN phone ELSE NULLIF(trim(p_phone), '') END,
    notes = CASE WHEN p_notes IS NULL THEN notes ELSE NULLIF(trim(p_notes), '') END,
    sort_order = COALESCE(p_sort_order, sort_order)
  WHERE id = p_branch_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('branch.updated', 'branch', p_branch_id::text, v_uid, v_changes);

  RETURN jsonb_build_object('success', true);
END
$$;

-- 4. public wrappers --------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_create_branch(
  p_name text,
  p_code text,
  p_base_currency text DEFAULT 'USD',
  p_supported_currencies text[] DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_sort_order int DEFAULT 0
) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER
SET search_path = public, pg_temp
AS $$ SELECT private.admin_create_branch(p_name, p_code, p_base_currency,
        p_supported_currencies, p_address, p_phone, p_notes, p_sort_order) $$;

CREATE OR REPLACE FUNCTION public.admin_update_branch(
  p_branch_id uuid,
  p_name text DEFAULT NULL,
  p_code text DEFAULT NULL,
  p_base_currency text DEFAULT NULL,
  p_supported_currencies text[] DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_sort_order int DEFAULT NULL,
  p_code_change_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER
SET search_path = public, pg_temp
AS $$ SELECT private.admin_update_branch(p_branch_id, p_name, p_code, p_base_currency,
        p_supported_currencies, p_address, p_phone, p_notes, p_sort_order, p_code_change_reason) $$;

GRANT EXECUTE ON FUNCTION public.admin_create_branch(text, text, text, text[], text, text, text, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_branch(uuid, text, text, text, text[], text, text, text, int, text) TO authenticated;
