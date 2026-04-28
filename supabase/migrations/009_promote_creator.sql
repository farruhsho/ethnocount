-- ============================================================
-- 009: Promote designated creator email + harden trigger
-- ============================================================
-- Business rule: farruh@gmail.com is always the root creator and manages
-- every other account. Runs idempotently:
--   1) if the user already exists → promote role to 'creator' + activate
--   2) signup trigger is updated so the email is auto-promoted on first login
--      (works even if the user signs up before this migration runs)
-- ============================================================

-- 1. Promote the row if it already exists.
UPDATE public.users
SET
  role = 'creator',
  is_active = true
WHERE lower(email) = 'farruh@gmail.com'
  AND (role IS DISTINCT FROM 'creator' OR is_active IS DISTINCT FROM true);

-- 2. Replace the trigger so the email is always promoted on creation.
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

  IF lower(NEW.email) = 'farruh@gmail.com' THEN
    -- Root creator is fixed by email and cannot be downgraded via signup metadata.
    v_final_role := 'creator';
  ELSE
    -- Bootstrap rule: very first user may claim 'creator'; otherwise accountant.
    SELECT count(*) INTO v_user_count FROM public.users;
    IF v_user_count = 0 AND v_requested_role = 'creator' THEN
      v_final_role := 'creator';
    ELSE
      v_final_role := 'accountant';
    END IF;
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
  ON CONFLICT (id) DO UPDATE
    SET role = EXCLUDED.role,
        is_active = true
    WHERE lower(EXCLUDED.email) = 'farruh@gmail.com';

  RETURN NEW;
END;
$$;

-- Trigger binding already exists from migration 008; recreate only if missing
-- (safe idempotency).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'on_auth_user_created'
  ) THEN
    CREATE TRIGGER on_auth_user_created
      AFTER INSERT ON auth.users
      FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
  END IF;
END $$;
