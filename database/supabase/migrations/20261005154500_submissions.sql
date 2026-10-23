-- Submissions list for the admin screens.
--
-- Adds crimescene.datereported, i.e. when it was reported (datetime is when
-- it happened). The database fills it in so the app can't fake "most recent".
-- And list_submissions(), newest first, with the reporter's name, a media
-- count and optional search.


-- --- 1. datereported
ALTER TABLE public.crimescene ADD COLUMN datereported timestamptz;

-- We don't know when existing rows were reported, so use when it happened
-- (capped at now) as a best guess.
UPDATE public.crimescene SET datereported = LEAST(datetime, now());

ALTER TABLE public.crimescene
  ALTER COLUMN datereported SET DEFAULT now(),
  ALTER COLUMN datereported SET NOT NULL;

CREATE INDEX idx_crimescene_datereported ON public.crimescene (datereported DESC);

-- The app can't set or change it: filled on insert, kept on update. The
-- service key can still set it, e.g. for imports.
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


-- --- 2. list_submissions
--   supabase.rpc('list_submissions')                       20 newest
--   supabase.rpc('list_submissions', params: {'p_search': ...})
-- 'INC-0042', 'inc 42', '#42' and '42' all find incident 42. Any other text
-- matches locations (case-insensitive), and '42' also matches locations with
-- "42" in them.
--
-- SECURITY INVOKER, so RLS decides: admins see everything, citizens their
-- own, investigators their assigned cases.
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
           -- escape LIKE wildcards so % and _ are searched for literally
           replace(replace(replace(raw, '\', '\\'), '%', '\%'), '_', '\_') AS term,
           -- incident number, with or without the INC- prefix
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
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)   -- clamp to 1-100 rows
$$;

REVOKE EXECUTE ON FUNCTION public.list_submissions(text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.list_submissions(text, integer) TO authenticated, service_role;
