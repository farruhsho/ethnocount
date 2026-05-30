-- ============================================================
-- 048: accountant can manage accounts in own (assigned) branches
-- ============================================================
-- Раньше счета филиалов мог создавать/менять/архивировать только
-- creator (см. 011_admin_hardening, проверки `private.is_creator()`).
-- Бухгалтеры жаловались что не могут открыть новую кассу или поправить
-- название/комментарий счёта в своём филиале без участия creator-а.
--
-- Новая семантика:
--   • creator   — все филиалы, все счета
--   • director  — все филиалы (full visibility, как и у creator)
--   • accountant — только счета филиалов из его assigned_branch_ids
--
-- Меняем:
--   1) Новый helper `private.user_can_manage_branch_account(uuid)`,
--      true для creator/director ИЛИ accountant с branch в assigned.
--   2) admin_create_branch_account / admin_update_branch_account /
--      admin_archive_branch_account / admin_reorder_branch_accounts
--      используют этот helper вместо `is_creator()`.
--   3) RLS branch_accounts_insert / _update тоже расширяются.
--
-- Идемпотентно. CREATE OR REPLACE / DROP POLICY IF EXISTS.
-- ============================================================

BEGIN;

-- ─── 1. helper ───────────────────────────────────────────────
-- Принимает branch_id (для update/archive нужно сначала достать
-- branch_id по account_id — см. функции ниже).
CREATE OR REPLACE FUNCTION private.user_can_manage_branch_account(
  p_branch_id uuid
) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    -- creator всегда может
    private.is_creator()
    OR
    -- director — full visibility, тоже всегда
    private.is_director()
    OR
    -- accountant — только свои филиалы
    EXISTS (
      SELECT 1
        FROM public.users u
       WHERE u.id = auth.uid()
         AND u.role::text = 'accountant'
         AND u.is_active = true
         AND p_branch_id::text = ANY(COALESCE(u.assigned_branch_ids, '{}'))
    );
$$;

GRANT EXECUTE ON FUNCTION private.user_can_manage_branch_account(uuid) TO authenticated;


-- ─── 2. admin_create_branch_account ──────────────────────────
CREATE OR REPLACE FUNCTION private.admin_create_branch_account(
  p_branch_id uuid,
  p_name text,
  p_type text,
  p_currency text,
  p_card_number text DEFAULT NULL,
  p_cardholder_name text DEFAULT NULL,
  p_bank_name text DEFAULT NULL,
  p_expiry_month smallint DEFAULT NULL,
  p_expiry_year smallint DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_sort_order int DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_id uuid;
BEGIN
  IF NOT private.user_can_manage_branch_account(p_branch_id) THEN
    RAISE EXCEPTION 'Нет прав на создание счетов в этом филиале';
  END IF;
  IF coalesce(trim(p_name), '') = '' THEN RAISE EXCEPTION 'Название счёта обязательно'; END IF;
  IF p_type NOT IN ('cash','card','reserve','transit') THEN
    RAISE EXCEPTION 'Неверный тип счёта: %', p_type;
  END IF;

  INSERT INTO public.branch_accounts (
    branch_id, name, type, currency, card_number, cardholder_name, bank_name,
    expiry_month, expiry_year, notes, sort_order, is_active
  ) VALUES (
    p_branch_id, trim(p_name), p_type, coalesce(p_currency, 'USD'),
    NULLIF(trim(p_card_number), ''), NULLIF(trim(p_cardholder_name), ''), NULLIF(trim(p_bank_name), ''),
    p_expiry_month, p_expiry_year, NULLIF(trim(p_notes), ''), coalesce(p_sort_order, 0), true
  ) RETURNING id INTO v_id;

  INSERT INTO public.account_balances (account_id, branch_id, balance, currency, updated_at)
  VALUES (v_id, p_branch_id, 0, coalesce(p_currency, 'USD'), now())
  ON CONFLICT (account_id) DO NOTHING;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('account.created', 'branch_account', v_id::text, v_uid,
          jsonb_build_object('branchId', p_branch_id::text, 'name', p_name, 'type', p_type,
                             'currency', p_currency,
                             'hasCardNumber', p_card_number IS NOT NULL AND trim(p_card_number) <> ''));

  RETURN jsonb_build_object('success', true, 'accountId', v_id::text);
END
$$;


-- ─── 3. admin_update_branch_account ──────────────────────────
CREATE OR REPLACE FUNCTION private.admin_update_branch_account(
  p_account_id uuid,
  p_name text DEFAULT NULL,
  p_type text DEFAULT NULL,
  p_currency text DEFAULT NULL,
  p_card_number text DEFAULT NULL,
  p_clear_card_number boolean DEFAULT false,
  p_cardholder_name text DEFAULT NULL,
  p_bank_name text DEFAULT NULL,
  p_expiry_month smallint DEFAULT NULL,
  p_expiry_year smallint DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_sort_order int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_acc public.branch_accounts%ROWTYPE;
BEGIN
  SELECT * INTO v_acc FROM public.branch_accounts WHERE id = p_account_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Счёт не найден'; END IF;

  IF NOT private.user_can_manage_branch_account(v_acc.branch_id) THEN
    RAISE EXCEPTION 'Нет прав на изменение счетов в этом филиале';
  END IF;

  IF p_type IS NOT NULL AND p_type NOT IN ('cash','card','reserve','transit') THEN
    RAISE EXCEPTION 'Неверный тип счёта: %', p_type;
  END IF;

  UPDATE public.branch_accounts SET
    name = COALESCE(NULLIF(trim(p_name), ''), name),
    type = COALESCE(p_type, type),
    currency = COALESCE(p_currency, currency),
    card_number = CASE
                    WHEN p_clear_card_number THEN NULL
                    WHEN p_card_number IS NOT NULL THEN NULLIF(trim(p_card_number), '')
                    ELSE card_number
                  END,
    cardholder_name = CASE WHEN p_cardholder_name IS NULL THEN cardholder_name ELSE NULLIF(trim(p_cardholder_name), '') END,
    bank_name = CASE WHEN p_bank_name IS NULL THEN bank_name ELSE NULLIF(trim(p_bank_name), '') END,
    expiry_month = COALESCE(p_expiry_month, expiry_month),
    expiry_year = COALESCE(p_expiry_year, expiry_year),
    notes = CASE WHEN p_notes IS NULL THEN notes ELSE NULLIF(trim(p_notes), '') END,
    sort_order = COALESCE(p_sort_order, sort_order)
  WHERE id = p_account_id;

  IF p_currency IS NOT NULL AND p_currency <> v_acc.currency THEN
    UPDATE public.account_balances SET currency = p_currency, updated_at = now()
    WHERE account_id = p_account_id;
  END IF;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('account.updated', 'branch_account', p_account_id::text, v_uid,
          jsonb_build_object('cardNumberChanged',
            (p_clear_card_number OR (p_card_number IS NOT NULL AND NULLIF(trim(p_card_number), '') IS DISTINCT FROM v_acc.card_number))));

  RETURN jsonb_build_object('success', true);
END
$$;


-- ─── 4. admin_archive_branch_account ─────────────────────────
CREATE OR REPLACE FUNCTION private.admin_archive_branch_account(
  p_account_id uuid,
  p_archive boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_branch_id uuid;
BEGIN
  SELECT branch_id INTO v_branch_id FROM public.branch_accounts WHERE id = p_account_id;
  IF v_branch_id IS NULL THEN RAISE EXCEPTION 'Счёт не найден'; END IF;

  IF NOT private.user_can_manage_branch_account(v_branch_id) THEN
    RAISE EXCEPTION 'Нет прав на архивирование счетов в этом филиале';
  END IF;

  UPDATE public.branch_accounts SET
    is_active = NOT p_archive,
    archived_at = CASE WHEN p_archive THEN now() ELSE NULL END
  WHERE id = p_account_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES (CASE WHEN p_archive THEN 'account.archived' ELSE 'account.unarchived' END,
          'branch_account', p_account_id::text, v_uid, '{}'::jsonb);

  RETURN jsonb_build_object('success', true);
END
$$;


-- ─── 5. admin_reorder_branch_accounts ────────────────────────
CREATE OR REPLACE FUNCTION private.admin_reorder_branch_accounts(
  p_branch_id uuid,
  p_order jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_entry jsonb;
  v_count int := 0;
BEGIN
  IF NOT private.user_can_manage_branch_account(p_branch_id) THEN
    RAISE EXCEPTION 'Нет прав на изменение порядка счетов в этом филиале';
  END IF;
  IF p_order IS NULL OR jsonb_typeof(p_order) <> 'array' THEN
    RAISE EXCEPTION 'p_order должен быть массивом {accountId, sortOrder}';
  END IF;

  FOR v_entry IN SELECT * FROM jsonb_array_elements(p_order)
  LOOP
    UPDATE public.branch_accounts
       SET sort_order = (v_entry->>'sortOrder')::int
     WHERE id = (v_entry->>'accountId')::uuid AND branch_id = p_branch_id;
    v_count := v_count + 1;
  END LOOP;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('accounts.reordered', 'branch', p_branch_id::text, v_uid,
          jsonb_build_object('count', v_count));

  RETURN jsonb_build_object('success', true, 'count', v_count);
END
$$;


-- ─── 6. RLS policies ────────────────────────────────────────
-- Прямой INSERT/UPDATE через PostgREST остаётся доступным только
-- creator/admin для безопасности (accountant идёт через admin_* RPC
-- — там работает наш per-branch чек). Это не блокирует accountant-а:
-- RPC SECURITY DEFINER обходят RLS.
-- Но если в будущем кто-то захочет давать accountant прямой UPDATE
-- через PostgREST — можно расширить policy так:
--
--   USING (
--     private.get_user_role() IN ('creator', 'admin')
--     OR private.user_can_manage_branch_account(branch_id)
--   )
--
-- Сейчас RLS оставляем как было — accountant ходит только через RPC.

COMMIT;
