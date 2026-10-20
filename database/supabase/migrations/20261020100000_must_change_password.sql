-- =====================================================================
-- Temporary passwords: "must change password" until the user picks one
--
-- Admin and investigator accounts are created with a temporary password
-- chosen (usually generated) by whoever creates them:
--   * the root admin creates admins in the web console (create-admin)
--   * an admin creates investigators in the mobile app (create-investigator)
-- Both Edge Functions put must_change_password: true in the login's
-- app_metadata. Only the service key can write app_metadata, so a user
-- can't clear it themselves through the API.
--
-- The mobile app reads the flag at sign-in and shows the "Choose your
-- password" screen instead of the dashboard until the password is changed.
--
-- This trigger takes the flag off as soon as the password really changes
-- (in the app, or through a "Forgot password?" email link). It ignores the
-- first password set on a brand-new login (OLD password empty), so the flag
-- stays on while the account is being created.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.clear_must_change_password()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF NEW.raw_app_meta_data ? 'must_change_password'
     AND COALESCE(OLD.encrypted_password, '') <> ''
     AND NEW.encrypted_password IS DISTINCT FROM OLD.encrypted_password THEN
    NEW.raw_app_meta_data := NEW.raw_app_meta_data - 'must_change_password';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_password_changed ON auth.users;
CREATE TRIGGER on_auth_user_password_changed
  BEFORE UPDATE OF encrypted_password ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.clear_must_change_password();
