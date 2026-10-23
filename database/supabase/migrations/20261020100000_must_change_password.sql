-- Temporary passwords: the "must change password" flag.
--
-- Admins and investigators start out with a temporary password picked by
-- whoever created them (root creates admins in the web console, admins
-- create investigators in the app). Both Edge Functions set
-- must_change_password: true in app_metadata, and since only the service key
-- can write app_metadata nobody can just clear it themselves.
--
-- The app checks the flag at sign-in and shows "Choose your password"
-- instead of the dashboard until it's done.
--
-- This trigger clears the flag once the password actually changes, either in
-- the app or through a "Forgot password?" link. It ignores the very first
-- password on a new login (OLD password empty), otherwise the flag would be
-- cleared while the account is still being created.

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
