-- ============================================================
-- 008: Signup hardening — create public.users row via trigger
-- ============================================================
-- Fixes: PostgrestException 42501 on signUp → insert into users.
-- Root cause: client-side insert runs before the Supabase session is
--             attached to PostgREST (or with confirmation enabled, no
--             session exists at all), so auth.uid() is NULL → RLS denies.
-- Solution: auth.users AFTER INSERT trigger (SECURITY DEFINER) creates
--           the public.users profile row automatically, bypassing RLS.
-- Also guards: only the very first user may receive the 'creator' role.
-- Idempotent.
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_display_name text;
  v_requested_role text;
  v_final_role text;
  v_user_count bigint;
BEGIN
  v_display_name := COALESCE(
    NULLIF(trim(NEW.raw_user_meta_data->>'display_name'), ''),
    split_part(NEW.email, '@', 1),
    'User'
  );

  v_requested_role := COALESCE(NEW.raw_user_meta_data->>'signup_role', 'accountant');

  -- Only bootstrap: the first-ever user may claim 'creator'. Everyone else is 'accountant'.
  SELECT count(*) INTO v_user_count FROM public.users;
  IF v_user_count = 0 AND v_requested_role = 'creator' THEN
    v_final_role := 'creator';
  ELSE
    v_final_role := 'accountant';
  END IF;

  INSERT INTO public.users (
    id, display_name, email, role, assigned_branch_ids, is_active, created_at
  ) VALUES (
    NEW.id,
    v_display_name,
    NEW.email,
    v_final_role,
    ARRAY[]::text[],
    true,
    now()
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;

-- Drop any prior version to make this idempotent across re-runs
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
