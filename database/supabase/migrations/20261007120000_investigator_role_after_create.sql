-- Fix for accounts from create-investigator turning into citizens.
--
-- Auth's admin createUser saves a login in two steps in one transaction: it
-- inserts auth.users, then updates it to add app_metadata, which is where the
-- role lives. on_auth_user_created fires on the insert, sees no role and
-- makes a citizen.
--
-- This trigger catches the follow-up update. When a brand new login gets
-- 'investigator' or 'admin', we swap the citizen rows for the right ones.
-- Same transaction, so if something fails (say the badge number is taken) the
-- whole login rolls back and the admin gets an error instead of a half-made
-- account.
--
-- We only touch logins less than 5 minutes old, so existing citizens are
-- never affected. Safe to run more than once, or to paste into the SQL Editor.

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
    RETURN NEW; -- not a brand new login, leave it alone
  END IF;

  SELECT userid, role::text INTO v_userid, v_current
  FROM public."User"
  WHERE authid = NEW.id;

  IF v_userid IS NULL OR v_current IS DISTINCT FROM 'citizen' THEN
    RETURN NEW; -- no row yet, or the role is already right
  END IF;

  -- the citizen row references ("User".userid, role), so it has to go
  -- before the role can change
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
  -- admins: the "User" row is enough

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
