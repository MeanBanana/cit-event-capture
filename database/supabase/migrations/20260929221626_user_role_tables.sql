-- =====================================================================
-- Argus Shield: user roles as an enum + citizen / investigator sub-tables
--
--   "User"       shared by everyone: username, first name, surname, email,
--                phone number, role (enum: citizen | investigator | admin)
--   citizen      extra citizen details      (residence)
--   investigator extra investigator details (rank, badge number, station,
--                unit, duty status)
--   Admins have no extra details, so they only need a "User" row.
--
-- Passwords and login tokens are NOT stored here: Supabase Auth keeps them
-- in auth.users. "User".authid links each profile to its auth account.
--
-- Account creation:
--   * Citizens register in the app (supabase.auth.signUp). A trigger creates
--     their "User" + citizen rows from the sign-up data. App sign-ups are
--     ALWAYS citizens.
--   * Investigators are created by an admin through the create-investigator
--     Edge Function (service key). The role is passed in app_metadata, which
--     only the service key can set, so no one can make themselves staff.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Role becomes an enum
--    The user_select policy reads the role column, and Postgres won't change
--    a column's type while a policy uses it: drop it, convert, recreate it
--    exactly as it was.
-- ---------------------------------------------------------------------
CREATE TYPE public.user_role AS ENUM ('citizen', 'investigator', 'admin');

DROP POLICY "user_select" ON public."User";

-- the enum now does the job of the old CHECK constraint
ALTER TABLE public."User" DROP CONSTRAINT "User_role_check";

ALTER TABLE public."User"
  ALTER COLUMN role TYPE public.user_role USING role::text::public.user_role;

CREATE POLICY "user_select" ON public."User"
  FOR SELECT TO authenticated
  USING (
       authid = (SELECT auth.uid())
    OR (SELECT public.current_user_role()) = 'admin'
    -- investigators can see fellow investigators (collaboration)
    OR ((SELECT public.current_user_role()) = 'investigator' AND role = 'investigator')
  );


-- ---------------------------------------------------------------------
-- 2. Shared fields on "User"
-- ---------------------------------------------------------------------
ALTER TABLE public."User"
  ADD COLUMN username    varchar(30),
  ADD COLUMN firstname   varchar(100),
  ADD COLUMN surname     varchar(100),
  ADD COLUMN phonenumber varchar(20);

-- Backfill rows that already exist (fullname is split on the first space)
UPDATE public."User"
SET username  = 'user_' || userid,
    firstname = split_part(fullname, ' ', 1),
    surname   = trim(regexp_replace(fullname, '^\S+\s*', ''));

ALTER TABLE public."User"
  ALTER COLUMN username  SET NOT NULL,
  ALTER COLUMN firstname SET NOT NULL,
  ALTER COLUMN surname   SET NOT NULL,
  ADD CONSTRAINT "User_username_format" CHECK (username ~ '^[A-Za-z0-9_.]{3,30}$'),
  -- lets the sub-tables reference (userid, role), so a citizen row can only
  -- belong to a citizen and an investigator row only to an investigator
  ADD CONSTRAINT "User_userid_role_key" UNIQUE (userid, role);

-- usernames are unique ignoring case ("DeacsGNel" = "deacsgnel")
CREATE UNIQUE INDEX "User_username_lower_key" ON public."User" (lower(username));


-- ---------------------------------------------------------------------
-- 3. Sub-tables: each row extends exactly one "User" row
-- ---------------------------------------------------------------------
CREATE TABLE public.citizen (
  userid    integer          PRIMARY KEY,
  role      public.user_role NOT NULL DEFAULT 'citizen' CHECK (role = 'citizen'),
  residence text,          -- the registration screen should require this
  CONSTRAINT citizen_user_fkey FOREIGN KEY (userid, role)
    REFERENCES public."User" (userid, role) ON DELETE CASCADE
);

CREATE TABLE public.investigator (
  userid      integer          PRIMARY KEY,
  role        public.user_role NOT NULL DEFAULT 'investigator' CHECK (role = 'investigator'),
  rank        varchar(50),                        -- e.g. 'Sgt.'
  badgenumber varchar(50)      NOT NULL,          -- e.g. 'JHB-4471'
  station     varchar(150)     NOT NULL,          -- e.g. 'Kempton Park SAPS'
  unit        varchar(100),                       -- e.g. 'CIT Task Force'
  dutystatus  varchar(20)      NOT NULL DEFAULT 'available'
              CHECK (dutystatus IN ('on_duty', 'available', 'off_duty')),
  CONSTRAINT investigator_badgenumber_key UNIQUE (badgenumber),
  CONSTRAINT investigator_user_fkey FOREIGN KEY (userid, role)
    REFERENCES public."User" (userid, role) ON DELETE CASCADE
);

ALTER TABLE public.citizen      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.investigator ENABLE ROW LEVEL SECURITY;


-- ---------------------------------------------------------------------
-- 4. Move existing users into their sub-tables
-- ---------------------------------------------------------------------
INSERT INTO public.citizen (userid)
  SELECT userid FROM public."User" WHERE role = 'citizen';

INSERT INTO public.investigator (userid, badgenumber, station)
  SELECT userid, COALESCE(badgenumber, 'PENDING-' || userid), 'unassigned'
  FROM public."User" WHERE role = 'investigator';


-- ---------------------------------------------------------------------
-- 5. "User" column protection no longer mentions badgenumber
--    (users may still edit their own username, name and phone number)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_user_columns()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon')
     AND public.current_user_role() IS DISTINCT FROM 'admin'
     AND (   NEW.role        IS DISTINCT FROM OLD.role
          OR NEW.email       IS DISTINCT FROM OLD.email
          OR NEW.authid      IS DISTINCT FROM OLD.authid
          OR NEW.userid      IS DISTINCT FROM OLD.userid
          OR NEW.datecreated IS DISTINCT FROM OLD.datecreated)
  THEN
    RAISE EXCEPTION 'Only admins can change role, email or account links';
  END IF;
  RETURN NEW;
END;
$$;


-- ---------------------------------------------------------------------
-- 6. Drop the columns that were replaced (fullname) or moved (badgenumber)
-- ---------------------------------------------------------------------
ALTER TABLE public."User"
  DROP COLUMN fullname,
  DROP COLUMN badgenumber;


-- ---------------------------------------------------------------------
-- 7. Sign-up trigger: creates "User" + the matching sub-table row
--    Role comes from raw_app_meta_data (service key only). App sign-ups
--    never have it there, so they always become citizens.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_role   text  := COALESCE(NEW.raw_app_meta_data ->> 'role', 'citizen');
  v_meta   jsonb := COALESCE(NEW.raw_user_meta_data, '{}'::jsonb);
  v_userid integer;
BEGIN
  IF v_role NOT IN ('citizen', 'investigator', 'admin') THEN
    RAISE EXCEPTION 'Invalid role: %', v_role;
  END IF;

  INSERT INTO public."User" (authid, username, firstname, surname, email, phonenumber, role)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(trim(v_meta ->> 'username'), ''),
             'user_' || substr(replace(NEW.id::text, '-', ''), 1, 10)),
    COALESCE(NULLIF(trim(v_meta ->> 'firstname'), ''), split_part(NEW.email, '@', 1)),
    COALESCE(NULLIF(trim(v_meta ->> 'surname'), ''), ''),
    NEW.email,
    NULLIF(trim(v_meta ->> 'phonenumber'), ''),
    v_role::public.user_role
  )
  RETURNING userid INTO v_userid;

  IF v_role = 'citizen' THEN
    INSERT INTO public.citizen (userid, residence)
    VALUES (v_userid, NULLIF(trim(v_meta ->> 'residence'), ''));
  ELSIF v_role = 'investigator' THEN
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
-- on_auth_user_created (from 20260929114152_auth_and_rls.sql) already calls
-- this function, so the trigger itself does not need to be recreated.


-- ---------------------------------------------------------------------
-- 8. Keep "User".email in sync when someone changes their login email
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_auth_email_change()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  UPDATE public."User" SET email = NEW.email WHERE authid = NEW.id;
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.handle_auth_email_change() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER on_auth_user_email_changed
  AFTER UPDATE OF email ON auth.users
  FOR EACH ROW
  WHEN (OLD.email IS DISTINCT FROM NEW.email)
  EXECUTE FUNCTION public.handle_auth_email_change();


-- ---------------------------------------------------------------------
-- 9. Investigators may change ONLY their own duty status
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_investigator_columns()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon')
     AND public.current_user_role() IS DISTINCT FROM 'admin'
     AND (   NEW.userid      IS DISTINCT FROM OLD.userid
          OR NEW.rank        IS DISTINCT FROM OLD.rank
          OR NEW.badgenumber IS DISTINCT FROM OLD.badgenumber
          OR NEW.station     IS DISTINCT FROM OLD.station
          OR NEW.unit        IS DISTINCT FROM OLD.unit)
  THEN
    RAISE EXCEPTION 'Investigators can only change their duty status';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_investigator_columns
  BEFORE UPDATE ON public.investigator
  FOR EACH ROW EXECUTE FUNCTION public.protect_investigator_columns();


-- ---------------------------------------------------------------------
-- 10. Username helpers for the login and registration screens
--     (callable before logging in, via supabase.rpc)
-- ---------------------------------------------------------------------
-- Login: username -> the email Supabase Auth needs to sign in
CREATE OR REPLACE FUNCTION public.email_for_username(p_username text)
  RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT email::text FROM public."User" WHERE lower(username) = lower(trim(p_username))
$$;

-- Registration: is this username still free?
CREATE OR REPLACE FUNCTION public.username_available(p_username text)
  RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM public."User" WHERE lower(username) = lower(trim(p_username))
  )
$$;

REVOKE EXECUTE ON FUNCTION public.email_for_username(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.username_available(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.email_for_username(text) TO anon, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.username_available(text) TO anon, authenticated, service_role;


-- ---------------------------------------------------------------------
-- 11. Privileges: sub-table rows are only created by the sign-up trigger
-- ---------------------------------------------------------------------
REVOKE ALL ON public.citizen, public.investigator FROM anon;
REVOKE INSERT, DELETE, TRUNCATE, TRIGGER, REFERENCES
  ON public.citizen, public.investigator FROM authenticated;


-- ---------------------------------------------------------------------
-- 12. Policies
-- ---------------------------------------------------------------------
-- citizen: own details; admins see/edit all
CREATE POLICY "citizen_select" ON public.citizen
  FOR SELECT TO authenticated
  USING (userid = (SELECT public.current_user_id())
         OR (SELECT public.current_user_role()) = 'admin');

CREATE POLICY "citizen_update" ON public.citizen
  FOR UPDATE TO authenticated
  USING      (userid = (SELECT public.current_user_id())
              OR (SELECT public.current_user_role()) = 'admin')
  WITH CHECK (userid = (SELECT public.current_user_id())
              OR (SELECT public.current_user_role()) = 'admin');

-- investigator: investigators and admins see all investigators;
-- an investigator updates their own row (duty status only, see trigger);
-- admins update any row
CREATE POLICY "investigator_select" ON public.investigator
  FOR SELECT TO authenticated
  USING ((SELECT public.current_user_role()) IN ('admin', 'investigator'));

CREATE POLICY "investigator_update" ON public.investigator
  FOR UPDATE TO authenticated
  USING      (userid = (SELECT public.current_user_id())
              OR (SELECT public.current_user_role()) = 'admin')
  WITH CHECK (userid = (SELECT public.current_user_id())
              OR (SELECT public.current_user_role()) = 'admin');