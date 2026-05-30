-- ============================================================
-- 059: UI-поддержка лимита экспозиции (F5)
-- ============================================================
-- Миграция 058 добавила колонку exposure_limit_by_currency и
-- enforcement в record_counterparty_op. Эта миграция даёт UI
-- возможность ЧИТАТЬ и ЗАДАВАТЬ лимит:
--   1) counterparties_list теперь отдаёт exposure_limit_by_currency
--      (нужен DROP+CREATE — меняется RETURNS TABLE).
--   2) update_counterparty принимает p_exposure_limit_by_currency
--      (jsonb {валюта: число}). Только creator/director — как fee.
--      NULL = не менять. '{}' = снять все лимиты.
--      Значения валидируются: оставляем только положительные числа.
--
-- Идемпотентно: DROP IF EXISTS + CREATE.
-- ============================================================

BEGIN;

-- ─── 1. counterparties_list отдаёт exposure_limit_by_currency ──
DROP FUNCTION IF EXISTS public.counterparties_list(boolean);
DROP FUNCTION IF EXISTS private.counterparties_list(boolean);

CREATE FUNCTION private.counterparties_list(
  p_include_archived boolean DEFAULT false
) RETURNS TABLE (
  id uuid,
  name text,
  city text,
  phone text,
  notes text,
  saldo_by_currency jsonb,
  exposure_limit_by_currency jsonb,
  is_active boolean,
  home_branch_id uuid,
  fee_percentage double precision,
  tx_count bigint,
  last_op_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    cp.id,
    cp.name,
    cp.city,
    cp.phone,
    cp.notes,
    cp.saldo_by_currency,
    cp.exposure_limit_by_currency,
    cp.is_active,
    cp.home_branch_id,
    cp.fee_percentage,
    COALESCE(t.tx_count, 0) AS tx_count,
    t.last_op_at
  FROM counterparties cp
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS tx_count,
           MAX(created_at) AS last_op_at
    FROM counterparty_transactions
    WHERE counterparty_id = cp.id
  ) t ON true
  WHERE p_include_archived OR cp.is_active
  ORDER BY cp.name;
$$;

CREATE FUNCTION public.counterparties_list(
  p_include_archived boolean DEFAULT false
) RETURNS TABLE (
  id uuid,
  name text,
  city text,
  phone text,
  notes text,
  saldo_by_currency jsonb,
  exposure_limit_by_currency jsonb,
  is_active boolean,
  home_branch_id uuid,
  fee_percentage double precision,
  tx_count bigint,
  last_op_at timestamptz
)
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT * FROM private.counterparties_list(p_include_archived);
$$;

GRANT EXECUTE ON FUNCTION public.counterparties_list(boolean) TO authenticated;

-- ─── 2. update_counterparty принимает p_exposure_limit_by_currency ──
DROP FUNCTION IF EXISTS public.update_counterparty(
  uuid, text, text, text, text, double precision, uuid, boolean, boolean);
DROP FUNCTION IF EXISTS private.update_counterparty(
  uuid, text, text, text, text, double precision, uuid, boolean, boolean);

CREATE FUNCTION private.update_counterparty(
  p_counterparty_id uuid,
  p_name text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_fee_percentage double precision DEFAULT NULL,
  p_home_branch_id uuid DEFAULT NULL,
  p_clear_home_branch boolean DEFAULT false,
  p_clear_fee boolean DEFAULT false,
  p_exposure_limit_by_currency jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_assigned text[];
  v_cp counterparties%ROWTYPE;
  v_clean_limit jsonb := '{}'::jsonb;
  v_key text;
  v_val jsonb;
  v_num numeric;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'User must be authenticated'; END IF;

  SELECT role::text, assigned_branch_ids
    INTO v_role, v_assigned
  FROM public.users WHERE id = v_uid;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'Профиль пользователя не найден';
  END IF;

  SELECT * INTO v_cp FROM counterparties
    WHERE id = p_counterparty_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Партнёр не найден'; END IF;

  -- Бухгалтер: только партнёры без home_branch_id или прикреплённые к
  -- его филиалу. Creator/director — без ограничений.
  IF v_role = 'accountant' THEN
    IF v_cp.home_branch_id IS NOT NULL
       AND NOT (v_cp.home_branch_id::text = ANY(COALESCE(v_assigned, ARRAY[]::text[]))) THEN
      RAISE EXCEPTION 'Этот партнёр привязан к чужому филиалу — править не можете';
    END IF;
    IF p_home_branch_id IS NOT NULL OR p_clear_home_branch THEN
      RAISE EXCEPTION 'Привязку к филиалу меняет только Creator/Director';
    END IF;
    IF p_fee_percentage IS NOT NULL OR p_clear_fee THEN
      RAISE EXCEPTION 'Комиссию партнёра меняет только Creator/Director';
    END IF;
    IF p_exposure_limit_by_currency IS NOT NULL THEN
      RAISE EXCEPTION 'Лимит экспозиции меняет только Creator/Director';
    END IF;
  END IF;

  IF p_name IS NOT NULL THEN
    IF length(trim(p_name)) < 2 THEN
      RAISE EXCEPTION 'Имя должно быть длиннее 1 символа';
    END IF;
  END IF;

  IF p_fee_percentage IS NOT NULL THEN
    IF p_fee_percentage < 0 THEN
      RAISE EXCEPTION 'Комиссия должна быть ≥ 0';
    END IF;
    IF p_fee_percentage > 50 THEN
      RAISE EXCEPTION 'Слишком большая комиссия: %', p_fee_percentage;
    END IF;
  END IF;

  IF p_home_branch_id IS NOT NULL THEN
    PERFORM 1 FROM public.branches WHERE id = p_home_branch_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Филиал не найден: %', p_home_branch_id;
    END IF;
  END IF;

  -- Санитизация лимита: оставляем только положительные числа, ключи в
  -- upper-case. Нечисловое/<=0 значение → пропускаем (снимаем лимит).
  IF p_exposure_limit_by_currency IS NOT NULL THEN
    IF jsonb_typeof(p_exposure_limit_by_currency) <> 'object' THEN
      RAISE EXCEPTION 'exposure_limit_by_currency должен быть JSON-объектом';
    END IF;
    FOR v_key, v_val IN
      SELECT * FROM jsonb_each(p_exposure_limit_by_currency)
    LOOP
      BEGIN
        v_num := (v_val #>> '{}')::numeric;
      EXCEPTION WHEN others THEN
        v_num := NULL;
      END;
      IF v_num IS NOT NULL AND v_num > 0 THEN
        v_clean_limit := v_clean_limit
          || jsonb_build_object(upper(trim(v_key)), round(v_num, 4));
      END IF;
    END LOOP;
  END IF;

  UPDATE counterparties SET
    name = COALESCE(NULLIF(trim(p_name), ''), name),
    city = CASE
      WHEN p_city IS NULL THEN city
      WHEN trim(p_city) = '' THEN NULL
      ELSE trim(p_city)
    END,
    phone = CASE
      WHEN p_phone IS NULL THEN phone
      WHEN trim(p_phone) = '' THEN NULL
      ELSE private.normalize_phone(p_phone)
    END,
    notes = CASE
      WHEN p_notes IS NULL THEN notes
      WHEN trim(p_notes) = '' THEN NULL
      ELSE trim(p_notes)
    END,
    fee_percentage = CASE
      WHEN p_clear_fee THEN NULL
      WHEN p_fee_percentage IS NULL THEN fee_percentage
      ELSE p_fee_percentage
    END,
    home_branch_id = CASE
      WHEN p_clear_home_branch THEN NULL
      WHEN p_home_branch_id IS NULL THEN home_branch_id
      ELSE p_home_branch_id
    END,
    exposure_limit_by_currency = CASE
      WHEN p_exposure_limit_by_currency IS NULL THEN exposure_limit_by_currency
      ELSE v_clean_limit
    END
  WHERE id = p_counterparty_id;

  RETURN jsonb_build_object('success', true);
END;
$$;

CREATE FUNCTION public.update_counterparty(
  p_counterparty_id uuid,
  p_name text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_fee_percentage double precision DEFAULT NULL,
  p_home_branch_id uuid DEFAULT NULL,
  p_clear_home_branch boolean DEFAULT false,
  p_clear_fee boolean DEFAULT false,
  p_exposure_limit_by_currency jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT private.update_counterparty(
    p_counterparty_id, p_name, p_city, p_phone, p_notes,
    p_fee_percentage, p_home_branch_id, p_clear_home_branch, p_clear_fee,
    p_exposure_limit_by_currency
  );
$$;

GRANT EXECUTE ON FUNCTION public.update_counterparty(
  uuid, text, text, text, text, double precision, uuid, boolean, boolean, jsonb
) TO authenticated;

COMMIT;
