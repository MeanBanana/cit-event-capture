-- =====================================================================
-- Argus Shield: submissions list for the admin screens
--
-- 1. crimescene.datereported: when the incident was REPORTED (datetime is
--    when it HAPPENED). Filled in by the database, so "most recent
--    submissions" can't be faked by the app.
-- 2. list_submissions(): newest reports first, with reporter name and
--    media count; optional search by incident number or location.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. datereported
-- ---------------------------------------------------------------------
ALTER TABLE public.crimescene ADD COLUMN datereported timestamptz;

-- Existing rows: we don't know when they were reported, so use when the
-- incident happened (never later than now) as the best guess.
UPDATE public.crimescene SET datereported = LEAST(datetime, now());

ALTER TABLE public.crimescene
  ALTER COLUMN datereported SET DEFAULT now(),
  ALTER COLUMN datereported SET NOT NULL;

CREATE INDEX idx_crimescene_datereported ON public.crimescene (datereported DESC);

-- App users can't choose or change it: set on insert, kept on update.
-- (The service key, e.g. for imports, may still set it.)
CREATE OR REPLACE FUNCTION public.set_crimescene_datereported()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') THEN
    IF TG_OP = 'INSERT' THEN
      NEW.datereported := now();
    ELSE
      NEW.datereported := OLD.datereported;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER set_crimescene_datereported
  BEFORE INSERT OR UPDATE ON public.crimescene
  FOR EACH ROW EXECUTE FUNCTION public.set_crimescene_datereported();


-- ---------------------------------------------------------------------
-- 2. list_submissions
--   supabase.rpc('list_submissions')                            -> 20 newest
--   supabase.rpc('list_submissions', params: {'p_search': ...})
--       'INC-0042', 'inc 42', '#42' or '42' -> incident 42
--       any text -> locations containing it (any case)
--       ('42' finds incident 42 AND locations containing "42")
--
-- SECURITY INVOKER: normal RLS applies - admins see every submission,
-- citizens only their own, investigators only their assigned cases.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_submissions(
  p_search text    DEFAULT NULL,
  p_limit  integer DEFAULT 20
)
  RETURNS TABLE (
    incidentid   integer,
    location     text,
    datetime     timestamptz,
    attacktype   varchar,
    status       varchar,
    description  text,
    reportedby   integer,
    reportername text,
    mediacount   integer,
    datereported timestamptz,
    caseid       integer
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  WITH q AS (
    SELECT NULLIF(trim(COALESCE(p_search, '')), '') AS raw
  ), t AS (
    SELECT raw,
           -- LIKE wildcards escaped so % and _ are searched for literally
           replace(replace(replace(raw, '\', '\\'), '%', '\%'), '_', '\_') AS term,
           -- an incident number, with or without the INC- prefix
           CASE WHEN raw ~* '^(inc)?[\s#-]*[0-9]{1,9}$'
                THEN substring(raw FROM '[0-9]+')::integer END AS num
    FROM q
  )
  SELECT cs.incidentid, cs.location, cs.datetime, cs.attacktype, cs.status,
         cs.description, cs.reportedby,
         NULLIF(trim(u.firstname || ' ' || u.surname), '') AS reportername,
         (SELECT count(*)::integer FROM public.media m
           WHERE m.incidentid = cs.incidentid) AS mediacount,
         cs.datereported, cs.caseid
  FROM public.crimescene cs
  LEFT JOIN public."User" u ON u.userid = cs.reportedby
  CROSS JOIN t
  WHERE t.raw IS NULL
     OR cs.incidentid = t.num
     OR cs.location ILIKE '%' || t.term || '%'
  ORDER BY cs.datereported DESC, cs.incidentid DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)   -- 1 to 100 rows
$$;

REVOKE EXECUTE ON FUNCTION public.list_submissions(text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.list_submissions(text, integer) TO authenticated, service_role;
