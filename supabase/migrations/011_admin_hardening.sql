-- ============================================================
-- 011: Admin hardening — branch/account model, scoped RLS,
--      auditable admin RPCs, self-edit protection.
-- ============================================================
-- Changes:
--   * branches: contact fields (address/phone/notes), sort_order,
--     archived_at. branch_code_history table for code audits.
--   * branch_accounts: card fields (card_number + generated card_last4,
--     cardholder_name, bank_name, expiry_month/year, notes),
--     sort_order, archived_at.
--   * Helpers private.is_creator() / private.user_branches() /
--     private.branch_allowed(uuid).
--   * RLS rewrite: branches, branch_accounts, account_balances,
--     transfers, ledger_entries, purchases, deleted_purchases,
--     commissions, notifications are scoped by assigned_branch_ids.
--   * Trigger users_protect_self_columns: accountants may only
--     change display_name / phone / photo_url on their own row.
--   * admin_* SECURITY DEFINER RPCs (private + public wrappers)
--     for all branch/account/user mutations, gated by is_creator()
--     and logging to audit_logs.
-- Idempotent — safe to re-run.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 1. Schema extensions
-- ─────────────────────────────────────────────────────────────

-- branches: contacts, archive, ordering
ALTER TABLE public.branches
  ADD COLUMN IF NOT EXISTS address text,
  ADD COLUMN IF NOT EXISTS phone text,
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS sort_order int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

-- branch_code_history: audit every code change
CREATE TABLE IF NOT EXISTS public.branch_code_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  branch_id uuid NOT NULL REFERENCES public.branches(id) ON DELETE CASCADE,
  old_code text NOT NULL,
  new_code text NOT NULL,
  changed_by uuid NOT NULL REFERENCES auth.users(id),
  reason text,
  changed_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_branch_code_history_branch
  ON public.branch_code_history (branch_id, changed_at DESC);
ALTER TABLE public.branch_code_history ENABLE ROW LEVEL SECURITY;

-- branch_accounts: cards + archive + ordering
ALTER TABLE public.branch_accounts
  ADD COLUMN IF NOT EXISTS card_number text,
  ADD COLUMN IF NOT EXISTS cardholder_name text,
  ADD COLUMN IF NOT EXISTS bank_name text,
  ADD COLUMN IF NOT EXISTS expiry_month smallint,
  ADD COLUMN IF NOT EXISTS expiry_year smallint,
  ADD COLUMN IF NOT EXISTS notes text,
  ADD COLUMN IF NOT EXISTS sort_order int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

-- card_last4 generated column (last 4 digits of the digit-only PAN)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'branch_accounts' AND column_name = 'card_last4'
  ) THEN
    ALTER TABLE public.branch_accounts
      ADD COLUMN card_last4 text GENERATED ALWAYS AS (
        CASE
          WHEN card_number IS NULL THEN NULL
          WHEN length(regexp_replace(card_number, '\D', '', 'g')) >= 4
            THEN right(regexp_replace(card_number, '\D', '', 'g'), 4)
          ELSE NULL
        END
      ) STORED;
  END IF;
END
$$;

-- Month range constraint (guard against bad input)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.branch_accounts'::regclass AND conname = 'branch_accounts_expiry_month_chk'
  ) THEN
    ALTER TABLE public.branch_accounts
      ADD CONSTRAINT branch_accounts_expiry_month_chk
      CHECK (expiry_month IS NULL OR (expiry_month BETWEEN 1 AND 12));
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.branch_accounts'::regclass AND conname = 'branch_accounts_expiry_year_chk'
  ) THEN
    ALTER TABLE public.branch_accounts
      ADD CONSTRAINT branch_accounts_expiry_year_chk
      CHECK (expiry_year IS NULL OR (expiry_year BETWEEN 2000 AND 2100));
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_branch_accounts_sort
  ON public.branch_accounts (branch_id, sort_order, name);

-- ─────────────────────────────────────────────────────────────
-- 2. Helper functions
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.is_creator()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid()
      AND role = 'creator'
      AND is_active = true
  );
$$;

CREATE OR REPLACE FUNCTION private.user_branches()
RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(assigned_branch_ids, '{}')
  FROM public.users
  WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION private.branch_allowed(p_branch_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT private.is_creator()
      OR p_branch_id::text = ANY(COALESCE(private.user_branches(), '{}'));
$$;

-- ─────────────────────────────────────────────────────────────
-- 3. RLS policy rewrite
-- ─────────────────────────────────────────────────────────────

-- branches ----------------------------------------------------
DROP POLICY IF EXISTS "branches_select" ON public.branches;
DROP POLICY IF EXISTS "branches_insert" ON public.branches;
DROP POLICY IF EXISTS "branches_update" ON public.branches;
DROP POLICY IF EXISTS "branches_delete" ON public.branches;
CREATE POLICY "branches_select" ON public.branches FOR SELECT TO authenticated
  USING (private.is_creator() OR id::text = ANY(private.user_branches()));
CREATE POLICY "branches_insert" ON public.branches FOR INSERT TO authenticated
  WITH CHECK (private.is_creator());
CREATE POLICY "branches_update" ON public.branches FOR UPDATE TO authenticated
  USING (private.is_creator())
  WITH CHECK (private.is_creator());
CREATE POLICY "branches_delete" ON public.branches FOR DELETE TO authenticated
  USING (private.is_creator());

-- branch_code_history: read=creator, write=only via admin RPC ---
DROP POLICY IF EXISTS "branch_code_history_select" ON public.branch_code_history;
CREATE POLICY "branch_code_history_select" ON public.branch_code_history FOR SELECT TO authenticated
  USING (private.is_creator());

-- branch_accounts ---------------------------------------------
DROP POLICY IF EXISTS "branch_accounts_select" ON public.branch_accounts;
DROP POLICY IF EXISTS "branch_accounts_insert" ON public.branch_accounts;
DROP POLICY IF EXISTS "branch_accounts_update" ON public.branch_accounts;
DROP POLICY IF EXISTS "branch_accounts_delete" ON public.branch_accounts;
CREATE POLICY "branch_accounts_select" ON public.branch_accounts FOR SELECT TO authenticated
  USING (private.branch_allowed(branch_id));
CREATE POLICY "branch_accounts_insert" ON public.branch_accounts FOR INSERT TO authenticated
  WITH CHECK (private.is_creator());
CREATE POLICY "branch_accounts_update" ON public.branch_accounts FOR UPDATE TO authenticated
  USING (private.is_creator())
  WITH CHECK (private.is_creator());
CREATE POLICY "branch_accounts_delete" ON public.branch_accounts FOR DELETE TO authenticated
  USING (private.is_creator());

-- account_balances --------------------------------------------
DROP POLICY IF EXISTS "account_balances_select" ON public.account_balances;
DROP POLICY IF EXISTS "account_balances_all" ON public.account_balances;
DROP POLICY IF EXISTS "account_balances_insert" ON public.account_balances;
DROP POLICY IF EXISTS "account_balances_update" ON public.account_balances;
CREATE POLICY "account_balances_select" ON public.account_balances FOR SELECT TO authenticated
  USING (private.branch_allowed(branch_id));
-- write is done only via SECURITY DEFINER RPCs; keep permissive WITH CHECK for service_role only
CREATE POLICY "account_balances_insert" ON public.account_balances FOR INSERT TO authenticated
  WITH CHECK (private.is_creator());
CREATE POLICY "account_balances_update" ON public.account_balances FOR UPDATE TO authenticated
  USING (private.is_creator())
  WITH CHECK (private.is_creator());

-- transfers ---------------------------------------------------
DROP POLICY IF EXISTS "transfers_select" ON public.transfers;
DROP POLICY IF EXISTS "transfers_insert" ON public.transfers;
DROP POLICY IF EXISTS "transfers_update" ON public.transfers;
CREATE POLICY "transfers_select" ON public.transfers FOR SELECT TO authenticated
  USING (
    private.is_creator()
    OR from_branch_id::text = ANY(private.user_branches())
    OR to_branch_id::text   = ANY(private.user_branches())
  );
CREATE POLICY "transfers_insert" ON public.transfers FOR INSERT TO authenticated
  WITH CHECK (
    private.is_creator()
    OR from_branch_id::text = ANY(private.user_branches())
  );
CREATE POLICY "transfers_update" ON public.transfers FOR UPDATE TO authenticated
  USING (
    private.is_creator()
    OR from_branch_id::text = ANY(private.user_branches())
    OR to_branch_id::text   = ANY(private.user_branches())
  );

-- ledger_entries ----------------------------------------------
DROP POLICY IF EXISTS "ledger_select" ON public.ledger_entries;
DROP POLICY IF EXISTS "ledger_insert" ON public.ledger_entries;
DROP POLICY IF EXISTS "ledger_update" ON public.ledger_entries;
CREATE POLICY "ledger_select" ON public.ledger_entries FOR SELECT TO authenticated
  USING (private.branch_allowed(branch_id));
CREATE POLICY "ledger_insert" ON public.ledger_entries FOR INSERT TO authenticated
  WITH CHECK (private.branch_allowed(branch_id));
CREATE POLICY "ledger_update" ON public.ledger_entries FOR UPDATE TO authenticated
  USING (private.branch_allowed(branch_id));

-- purchases ---------------------------------------------------
DROP POLICY IF EXISTS "purchases_select" ON public.purchases;
DROP POLICY IF EXISTS "purchases_insert" ON public.purchases;
DROP POLICY IF EXISTS "purchases_update" ON public.purchases;
DROP POLICY IF EXISTS "purchases_delete" ON public.purchases;
CREATE POLICY "purchases_select" ON public.purchases FOR SELECT TO authenticated
  USING (private.branch_allowed(branch_id));
CREATE POLICY "purchases_insert" ON public.purchases FOR INSERT TO authenticated
  WITH CHECK (private.branch_allowed(branch_id));
CREATE POLICY "purchases_update" ON public.purchases FOR UPDATE TO authenticated
  USING (private.branch_allowed(branch_id));
CREATE POLICY "purchases_delete" ON public.purchases FOR DELETE TO authenticated
  USING (private.branch_allowed(branch_id));

-- deleted_purchases -------------------------------------------
DROP POLICY IF EXISTS "deleted_purchases_select" ON public.deleted_purchases;
DROP POLICY IF EXISTS "deleted_purchases_insert" ON public.deleted_purchases;
CREATE POLICY "deleted_purchases_select" ON public.deleted_purchases FOR SELECT TO authenticated
  USING (branch_id IS NULL OR private.branch_allowed(branch_id));
CREATE POLICY "deleted_purchases_insert" ON public.deleted_purchases FOR INSERT TO authenticated
  WITH CHECK (branch_id IS NULL OR private.branch_allowed(branch_id));

-- commissions -------------------------------------------------
DROP POLICY IF EXISTS "commissions_select" ON public.commissions;
CREATE POLICY "commissions_select" ON public.commissions FOR SELECT TO authenticated
  USING (branch_id IS NULL OR private.branch_allowed(branch_id));

-- notifications -----------------------------------------------
DROP POLICY IF EXISTS "notif_select" ON public.notifications;
DROP POLICY IF EXISTS "notif_insert" ON public.notifications;
DROP POLICY IF EXISTS "notif_update" ON public.notifications;
CREATE POLICY "notif_select" ON public.notifications FOR SELECT TO authenticated
  USING (
    private.is_creator()
    OR target_user_id = auth.uid()
    OR target_branch_id = '' OR target_branch_id IS NULL
    OR target_branch_id = ANY(private.user_branches())
  );
CREATE POLICY "notif_insert" ON public.notifications FOR INSERT TO authenticated
  WITH CHECK (true);  -- writes come from SECURITY DEFINER RPCs or service_role
CREATE POLICY "notif_update" ON public.notifications FOR UPDATE TO authenticated
  USING (
    private.is_creator()
    OR target_user_id = auth.uid()
    OR target_branch_id = ANY(private.user_branches())
  );

-- ─────────────────────────────────────────────────────────────
-- 4. users: self-edit protection trigger
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.users_guard_self_edit()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Admin RPCs run SECURITY DEFINER as postgres; is_creator() is also true for
  -- the actual creator. Accountants editing their own row can only change
  -- display_name / phone / photo_url. Everything else must go through the
  -- admin_* RPCs.
  IF private.is_creator() THEN
    RETURN NEW;
  END IF;

  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Нельзя менять id пользователя';
  END IF;
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    RAISE EXCEPTION 'Недостаточно прав: смена роли';
  END IF;
  IF NEW.assigned_branch_ids IS DISTINCT FROM OLD.assigned_branch_ids THEN
    RAISE EXCEPTION 'Недостаточно прав: смена филиалов';
  END IF;
  IF NEW.permissions IS DISTINCT FROM OLD.permissions THEN
    RAISE EXCEPTION 'Недостаточно прав: смена разрешений';
  END IF;
  IF NEW.is_active IS DISTINCT FROM OLD.is_active THEN
    RAISE EXCEPTION 'Недостаточно прав: смена статуса активности';
  END IF;
  IF NEW.email IS DISTINCT FROM OLD.email THEN
    RAISE EXCEPTION 'Недостаточно прав: смена email';
  END IF;
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_users_guard_self_edit ON public.users;
CREATE TRIGGER trg_users_guard_self_edit
  BEFORE UPDATE ON public.users
  FOR EACH ROW
  EXECUTE FUNCTION private.users_guard_self_edit();

-- ─────────────────────────────────────────────────────────────
-- 5. Admin RPCs (SECURITY DEFINER, gated by is_creator())
-- ─────────────────────────────────────────────────────────────

-- 5.1 branch CRUD ---------------------------------------------

CREATE OR REPLACE FUNCTION private.admin_create_branch(
  p_name text,
  p_code text,
  p_base_currency text DEFAULT 'USD',
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
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Требуется авторизация'; END IF;
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может создавать филиалы'; END IF;
  IF coalesce(trim(p_name), '') = '' THEN RAISE EXCEPTION 'Название филиала обязательно'; END IF;
  IF coalesce(trim(p_code), '') = '' THEN RAISE EXCEPTION 'Код филиала обязателен'; END IF;

  INSERT INTO public.branches (name, code, base_currency, address, phone, notes, sort_order, is_active)
  VALUES (trim(p_name), trim(p_code), coalesce(p_base_currency, 'USD'), p_address, p_phone, p_notes, coalesce(p_sort_order, 0), true)
  RETURNING id INTO v_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('branch.created', 'branch', v_id::text, v_uid,
          jsonb_build_object('name', p_name, 'code', p_code, 'baseCurrency', p_base_currency));

  RETURN jsonb_build_object('success', true, 'branchId', v_id::text);
END
$$;

CREATE OR REPLACE FUNCTION private.admin_update_branch(
  p_branch_id uuid,
  p_name text DEFAULT NULL,
  p_code text DEFAULT NULL,
  p_base_currency text DEFAULT NULL,
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
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Требуется авторизация'; END IF;
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может изменять филиалы'; END IF;

  SELECT * INTO v_branch FROM public.branches WHERE id = p_branch_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Филиал не найден'; END IF;

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

  UPDATE public.branches SET
    name = COALESCE(NULLIF(trim(p_name), ''), name),
    code = COALESCE(NULLIF(trim(p_code), ''), code),
    base_currency = COALESCE(p_base_currency, base_currency),
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

CREATE OR REPLACE FUNCTION private.admin_archive_branch(
  p_branch_id uuid,
  p_archive boolean,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может архивировать филиалы'; END IF;

  UPDATE public.branches SET
    is_active = NOT p_archive,
    archived_at = CASE WHEN p_archive THEN now() ELSE NULL END
  WHERE id = p_branch_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Филиал не найден'; END IF;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES (CASE WHEN p_archive THEN 'branch.archived' ELSE 'branch.unarchived' END,
          'branch', p_branch_id::text, v_uid,
          jsonb_build_object('reason', p_reason));

  RETURN jsonb_build_object('success', true);
END
$$;

-- 5.2 branch_account CRUD -------------------------------------

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
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может создавать счета'; END IF;
  IF coalesce(trim(p_name), '') = '' THEN RAISE EXCEPTION 'Название счёта обязательно'; END IF;
  IF p_type NOT IN ('cash','card','reserve','transit') THEN
    RAISE EXCEPTION 'Неверный тип счёта: %', p_type;
  END IF;

  INSERT INTO public.branch_accounts (
    branch_id, name, type, currency, card_number, cardholder_name, bank_name,
    expiry_month, expiry_year, notes, sort_order, is_active
  )
  VALUES (
    p_branch_id, trim(p_name), p_type, coalesce(p_currency, 'USD'),
    NULLIF(trim(p_card_number), ''), NULLIF(trim(p_cardholder_name), ''), NULLIF(trim(p_bank_name), ''),
    p_expiry_month, p_expiry_year, NULLIF(trim(p_notes), ''), coalesce(p_sort_order, 0), true
  )
  RETURNING id INTO v_id;

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
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может изменять счета'; END IF;

  SELECT * INTO v_acc FROM public.branch_accounts WHERE id = p_account_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Счёт не найден'; END IF;

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

CREATE OR REPLACE FUNCTION private.admin_archive_branch_account(
  p_account_id uuid,
  p_archive boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может архивировать счета'; END IF;

  UPDATE public.branch_accounts SET
    is_active = NOT p_archive,
    archived_at = CASE WHEN p_archive THEN now() ELSE NULL END
  WHERE id = p_account_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Счёт не найден'; END IF;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES (CASE WHEN p_archive THEN 'account.archived' ELSE 'account.unarchived' END,
          'branch_account', p_account_id::text, v_uid, '{}'::jsonb);

  RETURN jsonb_build_object('success', true);
END
$$;

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
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может менять порядок счетов'; END IF;
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

-- 5.3 user admin ops ------------------------------------------

CREATE OR REPLACE FUNCTION private.admin_set_user_branches(
  p_user_id uuid,
  p_branch_ids text[]
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_old text[];
BEGIN
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может менять доступы'; END IF;

  SELECT assigned_branch_ids INTO v_old FROM public.users WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Пользователь не найден'; END IF;

  UPDATE public.users SET assigned_branch_ids = COALESCE(p_branch_ids, '{}') WHERE id = p_user_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('user.branches_set', 'user', p_user_id::text, v_uid,
          jsonb_build_object('from', to_jsonb(v_old), 'to', to_jsonb(p_branch_ids)));

  RETURN jsonb_build_object('success', true);
END
$$;

CREATE OR REPLACE FUNCTION private.admin_update_user_permissions(
  p_user_id uuid,
  p_permissions jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_old jsonb;
BEGIN
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может менять разрешения'; END IF;
  IF p_permissions IS NULL OR jsonb_typeof(p_permissions) <> 'object' THEN
    RAISE EXCEPTION 'p_permissions должен быть объектом';
  END IF;

  SELECT permissions INTO v_old FROM public.users WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Пользователь не найден'; END IF;

  UPDATE public.users SET permissions = p_permissions WHERE id = p_user_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('user.permissions_updated', 'user', p_user_id::text, v_uid,
          jsonb_build_object('from', v_old, 'to', p_permissions));

  RETURN jsonb_build_object('success', true);
END
$$;

CREATE OR REPLACE FUNCTION private.admin_set_user_role(
  p_user_id uuid,
  p_role text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text;
  v_old_role text;
  v_creators_left int;
BEGIN
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может менять роль'; END IF;
  IF p_role NOT IN ('creator', 'accountant') THEN
    RAISE EXCEPTION 'Неверная роль: %', p_role;
  END IF;

  SELECT email, role INTO v_email, v_old_role FROM public.users WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Пользователь не найден'; END IF;

  -- Защита корневого creator'а
  IF lower(v_email) = 'farruh@gmail.com' AND p_role <> 'creator' THEN
    RAISE EXCEPTION 'Роль корневого creator''а (farruh@gmail.com) не может быть понижена';
  END IF;

  -- Нельзя убрать последнего creator'а
  IF v_old_role = 'creator' AND p_role <> 'creator' THEN
    SELECT count(*) INTO v_creators_left FROM public.users WHERE role = 'creator' AND is_active AND id <> p_user_id;
    IF v_creators_left = 0 THEN
      RAISE EXCEPTION 'Нельзя понизить последнего активного Creator''а';
    END IF;
  END IF;

  UPDATE public.users SET role = p_role WHERE id = p_user_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('user.role_changed', 'user', p_user_id::text, v_uid,
          jsonb_build_object('from', v_old_role, 'to', p_role));

  RETURN jsonb_build_object('success', true);
END
$$;

CREATE OR REPLACE FUNCTION private.admin_set_user_active(
  p_user_id uuid,
  p_active boolean,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text;
  v_role text;
  v_creators_left int;
BEGIN
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может блокировать'; END IF;

  SELECT email, role INTO v_email, v_role FROM public.users WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Пользователь не найден'; END IF;

  IF lower(v_email) = 'farruh@gmail.com' AND NOT p_active THEN
    RAISE EXCEPTION 'Корневой creator (farruh@gmail.com) не может быть деактивирован';
  END IF;

  IF v_role = 'creator' AND NOT p_active THEN
    SELECT count(*) INTO v_creators_left FROM public.users WHERE role = 'creator' AND is_active AND id <> p_user_id;
    IF v_creators_left = 0 THEN
      RAISE EXCEPTION 'Нельзя деактивировать последнего активного Creator''а';
    END IF;
  END IF;

  UPDATE public.users SET is_active = p_active WHERE id = p_user_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES (CASE WHEN p_active THEN 'user.activated' ELSE 'user.deactivated' END,
          'user', p_user_id::text, v_uid,
          jsonb_build_object('reason', p_reason));

  RETURN jsonb_build_object('success', true);
END
$$;

CREATE OR REPLACE FUNCTION private.admin_update_user_profile(
  p_user_id uuid,
  p_display_name text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_photo_url text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF NOT private.is_creator() THEN RAISE EXCEPTION 'Только Creator может менять профиль'; END IF;

  UPDATE public.users SET
    display_name = CASE WHEN p_display_name IS NULL THEN display_name ELSE trim(p_display_name) END,
    phone = CASE WHEN p_phone IS NULL THEN phone ELSE NULLIF(trim(p_phone), '') END,
    photo_url = CASE WHEN p_photo_url IS NULL THEN photo_url ELSE NULLIF(trim(p_photo_url), '') END
  WHERE id = p_user_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('user.profile_updated', 'user', p_user_id::text, v_uid,
          jsonb_build_object(
            'displayName', p_display_name,
            'phone', p_phone,
            'photoUrl', p_photo_url IS NOT NULL
          ));

  RETURN jsonb_build_object('success', true);
END
$$;

-- ─────────────────────────────────────────────────────────────
-- 6. Public wrappers + GRANTs (по паттерну 010)
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_create_branch(
  p_name text,
  p_code text,
  p_base_currency text DEFAULT 'USD',
  p_address text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_sort_order int DEFAULT 0
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_create_branch(p_name, p_code, p_base_currency, p_address, p_phone, p_notes, p_sort_order) $$;

CREATE OR REPLACE FUNCTION public.admin_update_branch(
  p_branch_id uuid,
  p_name text DEFAULT NULL,
  p_code text DEFAULT NULL,
  p_base_currency text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_sort_order int DEFAULT NULL,
  p_code_change_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_update_branch(p_branch_id, p_name, p_code, p_base_currency, p_address, p_phone, p_notes, p_sort_order, p_code_change_reason) $$;

CREATE OR REPLACE FUNCTION public.admin_archive_branch(
  p_branch_id uuid, p_archive boolean, p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_archive_branch(p_branch_id, p_archive, p_reason) $$;

CREATE OR REPLACE FUNCTION public.admin_create_branch_account(
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
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_create_branch_account(
  p_branch_id, p_name, p_type, p_currency,
  p_card_number, p_cardholder_name, p_bank_name,
  p_expiry_month, p_expiry_year, p_notes, p_sort_order
) $$;

CREATE OR REPLACE FUNCTION public.admin_update_branch_account(
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
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_update_branch_account(
  p_account_id, p_name, p_type, p_currency,
  p_card_number, p_clear_card_number, p_cardholder_name, p_bank_name,
  p_expiry_month, p_expiry_year, p_notes, p_sort_order
) $$;

CREATE OR REPLACE FUNCTION public.admin_archive_branch_account(
  p_account_id uuid, p_archive boolean
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_archive_branch_account(p_account_id, p_archive) $$;

CREATE OR REPLACE FUNCTION public.admin_reorder_branch_accounts(
  p_branch_id uuid, p_order jsonb
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_reorder_branch_accounts(p_branch_id, p_order) $$;

CREATE OR REPLACE FUNCTION public.admin_set_user_branches(
  p_user_id uuid, p_branch_ids text[]
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_set_user_branches(p_user_id, p_branch_ids) $$;

CREATE OR REPLACE FUNCTION public.admin_update_user_permissions(
  p_user_id uuid, p_permissions jsonb
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_update_user_permissions(p_user_id, p_permissions) $$;

CREATE OR REPLACE FUNCTION public.admin_set_user_role(
  p_user_id uuid, p_role text
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_set_user_role(p_user_id, p_role) $$;

CREATE OR REPLACE FUNCTION public.admin_set_user_active(
  p_user_id uuid, p_active boolean, p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_set_user_active(p_user_id, p_active, p_reason) $$;

CREATE OR REPLACE FUNCTION public.admin_update_user_profile(
  p_user_id uuid, p_display_name text DEFAULT NULL, p_phone text DEFAULT NULL, p_photo_url text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_update_user_profile(p_user_id, p_display_name, p_phone, p_photo_url) $$;

-- GRANT EXECUTE для всех новых public.admin_* (REVOKE от anon/public).
DO $grant$
DECLARE
  fn text;
  names text[] := ARRAY[
    'admin_create_branch(text,text,text,text,text,text,int)',
    'admin_update_branch(uuid,text,text,text,text,text,text,int,text)',
    'admin_archive_branch(uuid,boolean,text)',
    'admin_create_branch_account(uuid,text,text,text,text,text,text,smallint,smallint,text,int)',
    'admin_update_branch_account(uuid,text,text,text,text,boolean,text,text,smallint,smallint,text,int)',
    'admin_archive_branch_account(uuid,boolean)',
    'admin_reorder_branch_accounts(uuid,jsonb)',
    'admin_set_user_branches(uuid,text[])',
    'admin_update_user_permissions(uuid,jsonb)',
    'admin_set_user_role(uuid,text)',
    'admin_set_user_active(uuid,boolean,text)',
    'admin_update_user_profile(uuid,text,text,text)'
  ];
BEGIN
  FOREACH fn IN ARRAY names LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated, service_role', fn);
  END LOOP;
END
$grant$;
