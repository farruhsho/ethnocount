-- ============================================================
-- 013: Director role + user deletion RPC
-- ============================================================
-- New role 'director':
--   * Manages accountants (create / edit / delete / branch assignment).
--   * Cannot see creators or other directors in the user list (RLS).
--   * Cannot manage branches, accounts, exchange rates, or audit logs.
--   * Only creator can promote a user to director (or demote one).
--
-- admin_delete_user RPC (creator-only) and matching admin-delete-user
-- Edge Function let creators delete users completely (auth + profile).
-- Director-driven deletes go through the same Edge Function but the
-- function only allows them to delete accountants.
--
-- Idempotent.
-- ============================================================

-- ─────────────────────────────────────────────────────────────
-- 1. Allow 'director' on the role column
-- ─────────────────────────────────────────────────────────────
-- pg_get_constraintdef rewrites "IN (...)" as "= ANY (ARRAY[...])",
-- so the older heuristic that searched for the literal "IN" missed
-- the constraint. Drop *any* check constraint on public.users that
-- references the role column, then add our updated one by a fixed name.

DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT conname
      FROM pg_constraint
     WHERE conrelid = 'public.users'::regclass
       AND contype = 'c'
       AND pg_get_constraintdef(oid) ~* '\mrole\M'
  LOOP
    EXECUTE format('ALTER TABLE public.users DROP CONSTRAINT %I', r.conname);
  END LOOP;
END
$$;

ALTER TABLE public.users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE public.users
  ADD CONSTRAINT users_role_check
  CHECK (role IN ('creator', 'director', 'accountant', 'admin'));

-- ─────────────────────────────────────────────────────────────
-- 2. Helpers: is_director / is_creator_or_director
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION private.is_director()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE id = auth.uid()
      AND role = 'director'
      AND is_active = true
  );
$$;

CREATE OR REPLACE FUNCTION private.is_creator_or_director()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT private.is_creator() OR private.is_director();
$$;

-- ─────────────────────────────────────────────────────────────
-- 3. Self-edit trigger: allow admin RPCs to update other rows
-- ─────────────────────────────────────────────────────────────
-- The trigger now only blocks privileged-field changes when the row
-- being modified is the caller's *own* row and they aren't a creator.
-- Admin RPCs (SECURITY DEFINER) modify other users' rows and are
-- already authorized internally, so they pass through.

CREATE OR REPLACE FUNCTION private.users_guard_self_edit()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF private.is_creator() THEN
    RETURN NEW;
  END IF;

  -- Modifying a different user's row → must come from an admin_* RPC
  -- (those gate themselves with explicit role checks).
  IF v_uid IS NULL OR NEW.id <> v_uid THEN
    RETURN NEW;
  END IF;

  -- Self-edit by non-creator: only profile fields may change.
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

-- ─────────────────────────────────────────────────────────────
-- 4. Users SELECT policy: directors don't see creators/directors
-- ─────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS "users_select" ON public.users;
CREATE POLICY "users_select" ON public.users FOR SELECT TO authenticated
  USING (
    -- everyone sees themselves
    id = auth.uid()
    -- creator sees everyone
    OR private.is_creator()
    -- director sees only accountants (not creators, not other directors)
    OR (private.is_director() AND role = 'accountant')
    -- accountants keep the previous behaviour (see everyone) so existing
    -- features (assignment widgets, transfers UI) keep working
    OR (NOT private.is_director() AND NOT private.is_creator())
  );

-- ─────────────────────────────────────────────────────────────
-- 5. Update admin_* RPCs to allow director on accountant targets
-- ─────────────────────────────────────────────────────────────

-- Helper: ensure caller may operate on this target user.
CREATE OR REPLACE FUNCTION private.assert_can_manage_user(p_target_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target_role text;
BEGIN
  IF private.is_creator() THEN
    RETURN;
  END IF;
  IF NOT private.is_director() THEN
    RAISE EXCEPTION 'Недостаточно прав';
  END IF;
  -- Director: only accountants
  SELECT role INTO v_target_role FROM public.users WHERE id = p_target_id;
  IF v_target_role IS NULL THEN
    RAISE EXCEPTION 'Пользователь не найден';
  END IF;
  IF v_target_role <> 'accountant' THEN
    RAISE EXCEPTION 'Director может управлять только бухгалтерами';
  END IF;
END
$$;

-- 5.1 set_user_branches — allow director (only on accountants)
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
  PERFORM private.assert_can_manage_user(p_user_id);

  SELECT assigned_branch_ids INTO v_old FROM public.users WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Пользователь не найден'; END IF;

  UPDATE public.users SET assigned_branch_ids = COALESCE(p_branch_ids, '{}') WHERE id = p_user_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('user.branches_set', 'user', p_user_id::text, v_uid,
          jsonb_build_object('from', to_jsonb(v_old), 'to', to_jsonb(p_branch_ids)));

  RETURN jsonb_build_object('success', true);
END
$$;

-- 5.2 update_user_permissions
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
  PERFORM private.assert_can_manage_user(p_user_id);
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

-- 5.3 set_user_role — creator only, now also accepts 'director'
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
  IF p_role NOT IN ('creator', 'director', 'accountant') THEN
    RAISE EXCEPTION 'Неверная роль: %', p_role;
  END IF;

  SELECT email, role INTO v_email, v_old_role FROM public.users WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Пользователь не найден'; END IF;

  IF lower(v_email) = 'farruh@gmail.com' AND p_role <> 'creator' THEN
    RAISE EXCEPTION 'Роль корневого creator''а (farruh@gmail.com) не может быть понижена';
  END IF;

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

-- 5.4 set_user_active — director may (de)activate accountants only
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
  PERFORM private.assert_can_manage_user(p_user_id);

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

-- 5.5 update_user_profile — director may edit accountants
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
  PERFORM private.assert_can_manage_user(p_user_id);

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
-- 6. admin_delete_user RPC — profile cleanup only
-- ─────────────────────────────────────────────────────────────
-- Removes the public.users row and audits the deletion. The auth.users
-- account is removed by the admin-delete-user Edge Function (which has
-- the service_role key required for auth.admin.deleteUser). Calling
-- this RPC alone is safe — auth.users → public.users uses ON DELETE
-- CASCADE so the auth row will sweep an orphan public row anyway.

CREATE OR REPLACE FUNCTION private.admin_delete_user(
  p_user_id uuid,
  p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text;
  v_role text;
  v_display_name text;
  v_creators_left int;
BEGIN
  PERFORM private.assert_can_manage_user(p_user_id);

  IF p_user_id = v_uid THEN
    RAISE EXCEPTION 'Нельзя удалить самого себя';
  END IF;

  SELECT email, role, display_name
    INTO v_email, v_role, v_display_name
    FROM public.users WHERE id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Пользователь не найден'; END IF;

  IF lower(v_email) = 'farruh@gmail.com' THEN
    RAISE EXCEPTION 'Корневой creator (farruh@gmail.com) не может быть удалён';
  END IF;

  IF v_role = 'creator' THEN
    SELECT count(*) INTO v_creators_left
      FROM public.users
     WHERE role = 'creator' AND is_active AND id <> p_user_id;
    IF v_creators_left = 0 THEN
      RAISE EXCEPTION 'Нельзя удалить последнего активного Creator''а';
    END IF;
  END IF;

  DELETE FROM public.users WHERE id = p_user_id;

  INSERT INTO public.audit_logs (action, entity_type, entity_id, performed_by, details)
  VALUES ('user.deleted', 'user', p_user_id::text, v_uid,
          jsonb_build_object(
            'email', v_email,
            'role', v_role,
            'displayName', v_display_name,
            'reason', p_reason
          ));

  RETURN jsonb_build_object('success', true);
END
$$;

-- ─────────────────────────────────────────────────────────────
-- 7. Public wrappers + GRANTs
-- ─────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_delete_user(
  p_user_id uuid, p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp
AS $$ SELECT private.admin_delete_user(p_user_id, p_reason) $$;

DO $grant$
DECLARE
  fn text;
  names text[] := ARRAY[
    'admin_delete_user(uuid,text)'
  ];
BEGIN
  FOREACH fn IN ARRAY names LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated, service_role', fn);
  END LOOP;
END
$grant$;
