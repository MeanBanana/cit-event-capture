-- Admin accounts per police station, plus the root admin.
--
-- Every admin is still a "User" with role 'admin', and now also gets a row
-- in admin: admin_type ('root' or 'normal'), admin_station (e.g. 'Kempton
-- Park SAPS'), createdby and datecreated.
--
-- root is the single system owner. They sign in to web/admin-console and
-- they're the only one who can create admins. normal admins run a station
-- from the mobile app's admin screens like before, and can still add
-- investigators.
--
-- Root's "New admin" form calls the create-admin Edge Function (the service
-- key never touches the browser), and the sign-up triggers below create both
-- the "User" row and a 'normal' admin row from the login's metadata. Root
-- itself gets made once, by hand, in the SQL Editor:
--     SELECT public.make_root_admin('their_username', 'Their station');
--
-- Enforced here, not just in the console: only ever one root, admin rows
-- only for "User"s with role 'admin', and nobody edits the admin table
-- directly from either app (root changes stations via set_admin_station()).

CREATE TYPE public.admin_type AS ENUM ('root', 'normal');

CREATE TABLE public.admin (
  userid        integer           PRIMARY KEY,
  role          public.user_role  NOT NULL DEFAULT 'admin' CHECK (role = 'admin'),
  admin_type    public.admin_type NOT NULL DEFAULT 'normal',
  admin_station varchar(150)      NOT NULL CHECK (length(btrim(admin_station)) > 0),
  createdby     integer           REFERENCES public."User" (userid) ON DELETE SET NULL,
  datecreated   timestamptz       NOT NULL DEFAULT now(),
  CONSTRAINT admin_user_fkey FOREIGN KEY (userid, role)
    REFERENCES public."User" (userid, role) ON DELETE CASCADE
);

-- there can only be one root
CREATE UNIQUE INDEX admin_one_root ON public.admin ((true)) WHERE admin_type = 'root';
CREATE INDEX idx_admin_station ON public.admin (admin_station);

ALTER TABLE public.admin ENABLE ROW LEVEL SECURITY;

-- existing admins become normal station admins, root can fill in their
-- station from the console later
INSERT INTO public.admin (userid, admin_station)
  SELECT userid, 'Unassigned' FROM public."User" WHERE role = 'admin'
  ON CONFLICT (userid) DO NOTHING;


-- --- helpers
CREATE OR REPLACE FUNCTION public.is_root_admin()
  RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.admin a
    WHERE a.userid = public.current_user_id() AND a.admin_type = 'root'
  )
$$;

-- The signed-in admin, for the web console after login. NULL for anyone who
-- isn't an admin.
CREATE OR REPLACE FUNCTION public.current_admin()
  RETURNS jsonb
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT jsonb_build_object(
           'userid',        u.userid,
           'username',      u.username,
           'name',          btrim(concat_ws(' ', u.firstname, u.surname)),
           'email',         u.email,
           'admin_type',    a.admin_type,
           'admin_station', a.admin_station)
  FROM public.admin a
  JOIN public."User" u ON u.userid = a.userid
  WHERE a.userid = public.current_user_id()
$$;


-- --- root only: list admins, change an admin's station
CREATE OR REPLACE FUNCTION public.list_admins()
  RETURNS TABLE (
    userid          integer,
    username        text,
    firstname       text,
    surname         text,
    email           text,
    phonenumber     text,
    admin_type      public.admin_type,
    admin_station   text,
    datecreated     timestamptz,
    createdby_name  text,
    last_sign_in_at timestamptz
  )
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_root_admin() THEN
    RAISE EXCEPTION 'Only the root administrator can see the admin accounts'
      USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT u.userid, u.username::text, u.firstname::text, u.surname::text,
         u.email::text, u.phonenumber::text, a.admin_type,
         a.admin_station::text, a.datecreated,
         NULLIF(btrim(concat_ws(' ', c.firstname, c.surname)), ''),
         au.last_sign_in_at
  FROM public.admin a
  JOIN public."User" u ON u.userid = a.userid
  LEFT JOIN public."User" c ON c.userid = a.createdby
  LEFT JOIN auth.users au ON au.id = u.authid
  ORDER BY (a.admin_type = 'root') DESC, a.admin_station, u.surname, u.firstname;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_admin_station(p_userid integer, p_station text)
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_station text := btrim(COALESCE(p_station, ''));
BEGIN
  IF NOT public.is_root_admin() THEN
    RAISE EXCEPTION 'Only the root administrator can change an admin''s station'
      USING ERRCODE = '42501';
  END IF;
  IF v_station = '' OR length(v_station) > 150 THEN
    RAISE EXCEPTION 'Enter a station (at most 150 characters)' USING ERRCODE = '22023';
  END IF;
  UPDATE public.admin SET admin_station = v_station WHERE userid = p_userid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No admin with id %', p_userid USING ERRCODE = 'P0002';
  END IF;
END;
$$;


-- --- one-off, run in the SQL Editor: make an existing account the root admin
--   SELECT public.make_root_admin('deacs', 'Argus HQ');
-- Citizen and admin accounts get converted. Investigators are refused so
-- their case work doesn't end up orphaned.
CREATE OR REPLACE FUNCTION public.make_root_admin(p_username text, p_station text)
  RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_userid integer;
  v_role   text;
BEGIN
  SELECT userid, role::text INTO v_userid, v_role
  FROM public."User" WHERE lower(username) = lower(btrim(p_username));
  IF v_userid IS NULL THEN
    RAISE EXCEPTION 'No account with username %', p_username;
  END IF;
  IF EXISTS (SELECT 1 FROM public.admin WHERE admin_type = 'root' AND userid <> v_userid) THEN
    RAISE EXCEPTION 'There is already a root admin. Demote them first: '
      'UPDATE public.admin SET admin_type = ''normal'' WHERE admin_type = ''root'';';
  END IF;
  IF v_role = 'investigator' THEN
    RAISE EXCEPTION '% is an investigator. Use a separate account for the root admin.', p_username;
  END IF;
  IF v_role = 'citizen' THEN
    DELETE FROM public.citizen WHERE userid = v_userid;
    UPDATE public."User" SET role = 'admin' WHERE userid = v_userid;
  END IF;
  INSERT INTO public.admin (userid, admin_type, admin_station)
  VALUES (v_userid, 'root', COALESCE(NULLIF(btrim(p_station), ''), 'Argus HQ'))
  ON CONFLICT (userid) DO UPDATE
    SET admin_type = 'root',
        admin_station = COALESCE(NULLIF(btrim(p_station), ''), public.admin.admin_station);
  RETURN p_username || ' is now the root admin';
END;
$$;


-- --- sign-up triggers: an 'admin' login also gets an admin row, with the
-- station from its metadata. Always 'normal', root only gets made by hand.
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
  ELSE -- admin
    INSERT INTO public.admin (userid, admin_type, admin_station, createdby)
    VALUES (v_userid, 'normal',
            COALESCE(NULLIF(trim(v_meta ->> 'admin_station'), ''), 'Unassigned'),
            NULLIF(v_meta ->> 'createdby', '')::integer);
  END IF;

  RETURN NEW;
END;
$$;

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
  ELSE -- admin
    INSERT INTO public.admin (userid, admin_type, admin_station, createdby)
    VALUES (v_userid, 'normal',
            COALESCE(NULLIF(trim(v_meta ->> 'admin_station'), ''), 'Unassigned'),
            NULLIF(v_meta ->> 'createdby', '')::integer);
  END IF;

  RETURN NEW;
END;
$$;


-- --- privileges and policies
REVOKE ALL ON public.admin FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES ON public.admin FROM authenticated;
GRANT SELECT ON public.admin TO authenticated;
GRANT ALL ON public.admin TO service_role;

-- admins see their own row, root sees everyone's
CREATE POLICY "admin_select" ON public.admin
  FOR SELECT TO authenticated
  USING (userid = (SELECT public.current_user_id()) OR (SELECT public.is_root_admin()));

REVOKE EXECUTE ON FUNCTION public.is_root_admin()                   FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.current_admin()                   FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.list_admins()                     FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.set_admin_station(integer, text)  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.make_root_admin(text, text)       FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.is_root_admin()                   TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.current_admin()                   TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.list_admins()                     TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.set_admin_station(integer, text)  TO authenticated, service_role;
