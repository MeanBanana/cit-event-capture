-- Fix: accounts made by the create-investigator Edge Function became citizens.
--
-- Why: Supabase Auth's admin createUser saves a new login in two steps inside
-- one transaction: first it INSERTs the auth.users row, THEN it UPDATEs it to
-- add app_metadata (where the 'investigator' role lives). on_auth_user_created
-- runs on the INSERT, sees no role yet, and makes a citizen.
--
-- This trigger catches that follow-up UPDATE: when a brand-new login gets the
-- role 'investigator' or 'admin', its citizen rows are swapped for the right
-- ones. It runs in the same transaction, so if anything fails (for example a
-- badge number that is already taken) the whole login is rolled back and the
-- admin sees an error instead of a half-made account.
--
-- Only logins created in the last 5 minutes are changed, so this can never
-- touch an existing citizen and their data.
--
-- Safe to run more than once (also safe to paste into the SQL Editor).

CREATE OR REPLACE FUNCTION public.handle_auth_role_change()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_role    text  := NEW.raw_app_meta_data ->> 'role';
  v_meta    jsonb := COALESCE(NEW.raw_user_meta_data, '{}'::jsonb);
  v_userid  integer;
  v_current text;
BEGIN
  IF v_role IS NULL OR v_role NOT IN ('investigator', 'admin') THEN
    RETURN NEW;
  END IF;
  IF NEW.created_at < now() - interval '5 minutes' THEN
    RETURN NEW; -- not a brand-new login: leave it alone
  END IF;

  SELECT userid, role::text INTO v_userid, v_current
  FROM public."User"
  WHERE authid = NEW.id;

  IF v_userid IS NULL OR v_current IS DISTINCT FROM 'citizen' THEN
    RETURN NEW; -- no row yet, or already has the right role
  END IF;

  -- The citizen row points at ("User".userid, role), so it must go before
  -- the role can change.
  DELETE FROM public.citizen WHERE userid = v_userid;

  UPDATE public."User"
  SET role = v_role::public.user_role
  WHERE userid = v_userid;

  IF v_role = 'investigator' THEN
    INSERT INTO public.investigator (userid, rank, badgenumber, station, unit)
    VALUES (v_userid,
            NULLIF(trim(v_meta ->> 'rank'), ''),
            v_meta ->> 'badgenumber',
            v_meta ->> 'station',
            NULLIF(trim(v_meta ->> 'unit'), ''));
  END IF;
  -- admins: the "User" row is all they need

  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.handle_auth_role_change() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS on_auth_user_role_set ON auth.users;
CREATE TRIGGER on_auth_user_role_set
  AFTER UPDATE OF raw_app_meta_data ON auth.users
  FOR EACH ROW
  WHEN ((OLD.raw_app_meta_data ->> 'role') IS DISTINCT FROM (NEW.raw_app_meta_data ->> 'role'))
  EXECUTE FUNCTION public.handle_auth_role_change();
