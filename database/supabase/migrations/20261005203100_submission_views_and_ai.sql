-- AI descriptions, GPS, paging, grouping and match suggestions.
--
-- What's in here:
--   - AI fields that only the pipeline (service key) writes:
--     media.aidescription, and crimescene.aisummary / aisummarystatus
--     (none, processing, ready, outdated, failed) / aisummaryat. New footage
--     on an incident with a 'ready' summary flips it to 'outdated'.
--   - crimescene.latitude/longitude from the phone, and locationkey, a
--     normalised version of the location text so "N1, Midrand" and
--     "n1 midrand" end up in the same group.
--   - list_submissions with proper paging (30 at a time, cursor based),
--     filters, the AI summary and the little vehicle/people/weapon/plate chips.
--   - location groups, linked groups (via crossreferencelink) and list_cases
--     with paging and a preview of each case's submissions.
--   - incident_time(): the footage's own capture time beats whatever the
--     citizen typed. If the two are more than 3h apart we flag it so an admin
--     has a look.
--   - suggestions both ways (submission -> case, case -> submissions), each
--     with a score and readable reasons, plus a one-tap review screen.
--     Nothing ever joins a case without an admin saying yes.


-- --- 1. columns and indexes
ALTER TABLE public.media
  ADD COLUMN aidescription text,
  ADD COLUMN aidescribedat timestamptz;

ALTER TABLE public.crimescene
  ADD COLUMN latitude        numeric(9,6) CHECK (latitude  BETWEEN  -90 AND  90),
  ADD COLUMN longitude       numeric(9,6) CHECK (longitude BETWEEN -180 AND 180),
  ADD COLUMN aisummary       text CHECK (char_length(aisummary) <= 600),
  ADD COLUMN aisummarystatus varchar(20) NOT NULL DEFAULT 'none'
             CHECK (aisummarystatus IN ('none', 'processing', 'ready', 'outdated', 'failed')),
  ADD COLUMN aisummaryat     timestamptz,
  -- "N1, Midrand " -> "n1 midrand" (lower case, no punctuation, single
  -- spaces). This is what location grouping keys on.
  ADD COLUMN locationkey     text GENERATED ALWAYS AS (
             lower(trim(regexp_replace(location, '[^[:alnum:]]+', ' ', 'g')))) STORED,
  ADD CONSTRAINT crimescene_latlong_check CHECK ((latitude IS NULL) = (longitude IS NULL));

-- for paging: "next 30 after this one", in either direction
CREATE INDEX idx_crimescene_reported_id
  ON public.crimescene (datereported, incidentid);
CREATE INDEX idx_crimescene_review_reported_id
  ON public.crimescene (reviewstatus, datereported, incidentid);
CREATE INDEX idx_crimescene_case_reported_id
  ON public.crimescene (caseid, datereported, incidentid);
CREATE INDEX idx_crimescene_locationkey
  ON public.crimescene (locationkey, datereported, incidentid);
-- idx_crimescene_reported_id covers what the old single-column index did
DROP INDEX IF EXISTS public.idx_crimescene_datereported;


-- --- 2. only the pipeline (service key) may write the AI fields
CREATE OR REPLACE FUNCTION public.protect_crimescene_ai()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') AND (
       (TG_OP = 'INSERT' AND (NEW.aisummary IS NOT NULL
                              OR NEW.aisummarystatus <> 'none'
                              OR NEW.aisummaryat IS NOT NULL))
    OR (TG_OP = 'UPDATE' AND (NEW.aisummary       IS DISTINCT FROM OLD.aisummary
                              OR NEW.aisummarystatus IS DISTINCT FROM OLD.aisummarystatus
                              OR NEW.aisummaryat     IS DISTINCT FROM OLD.aisummaryat)))
  THEN
    RAISE EXCEPTION 'AI fields are written by the analysis pipeline only';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_crimescene_ai
  BEFORE INSERT OR UPDATE ON public.crimescene
  FOR EACH ROW EXECUTE FUNCTION public.protect_crimescene_ai();

CREATE OR REPLACE FUNCTION public.protect_media_ai()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') AND (
       (TG_OP = 'INSERT' AND (NEW.aidescription IS NOT NULL OR NEW.aidescribedat IS NOT NULL))
    OR (TG_OP = 'UPDATE' AND (NEW.aidescription IS DISTINCT FROM OLD.aidescription
                              OR NEW.aidescribedat IS DISTINCT FROM OLD.aidescribedat)))
  THEN
    RAISE EXCEPTION 'AI fields are written by the analysis pipeline only';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_media_ai
  BEFORE INSERT OR UPDATE ON public.media
  FOR EACH ROW EXECUTE FUNCTION public.protect_media_ai();

-- New footage on an incident that already has a finished summary means the
-- summary is now missing something, so mark it 'outdated'. SECURITY DEFINER
-- so this still works when it's a citizen doing the upload.
CREATE OR REPLACE FUNCTION public.mark_ai_summary_outdated()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  UPDATE public.crimescene
     SET aisummarystatus = 'outdated'
   WHERE incidentid = NEW.incidentid
     AND aisummarystatus = 'ready';
  RETURN NEW;
END;
$$;

CREATE TRIGGER mark_ai_summary_outdated
  AFTER INSERT ON public.media
  FOR EACH ROW EXECUTE FUNCTION public.mark_ai_summary_outdated();


-- --- 3. shared helpers
-- levenshtein() lives in the extensions schema on Supabase. We need it for
-- "plates one character apart".
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch WITH SCHEMA extensions;

-- capture times get looked up per incident
CREATE INDEX IF NOT EXISTS idx_media_incident_capture
  ON public.media (incidentid, capturetimestamp);

-- Best guess at when an incident happened: the earliest capture time from
-- its footage, falling back to what the citizen typed. Metadata is often
-- missing, e.g. anything forwarded through WhatsApp.
CREATE OR REPLACE FUNCTION public.incident_time(p_incidentid integer)
  RETURNS timestamptz
  LANGUAGE sql STABLE
  SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT min(m.capturetimestamp) FROM public.media m
      WHERE m.incidentid = p_incidentid),
    (SELECT cs.datetime FROM public.crimescene cs
      WHERE cs.incidentid = p_incidentid))
$$;

-- Two normalised plates exactly one character apart, i.e. the OCR mixed up
-- 0/O, 8/B, 1/I and so on. Anything shorter than 5 characters never counts,
-- too many different cars would match. Same rule as ai/case_matcher.py.
CREATE OR REPLACE FUNCTION public.plates_similar(p_a text, p_b text)
  RETURNS boolean
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$
  SELECT p_a IS NOT NULL AND p_b IS NOT NULL
     AND length(p_a) >= 5 AND length(p_b) >= 5
     AND abs(length(p_a) - length(p_b)) <= 1
     AND extensions.levenshtein(p_a, p_b) = 1
$$;

-- 'nd 123-456 gp' -> 'ND123456GP', NULL if nothing's left
CREATE OR REPLACE FUNCTION public.normalize_plate(p_plate text)
  RETURNS text
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$
  SELECT NULLIF(upper(regexp_replace(COALESCE(p_plate, ''), '[^A-Za-z0-9]', '', 'g')), '')
$$;

CREATE INDEX idx_vehicledetail_plate
  ON public.vehicledetail (public.normalize_plate(licenceplatenumber));

-- haversine distance in km, so we don't need PostGIS for this
CREATE OR REPLACE FUNCTION public.distance_km(
  lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
  RETURNS numeric
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$
  SELECT (2 * 6371 * asin(sqrt(
            power(sin(radians((lat2 - lat1)::double precision) / 2), 2)
          + cos(radians(lat1::double precision)) * cos(radians(lat2::double precision))
          * power(sin(radians((lon2 - lon1)::double precision) / 2), 2))))::numeric
$$;

-- Pairs of incidents linked through crossreferencelink, ignoring rejected
-- links. For vehicle links entityid_a/b are vehicledetail.vehicledetectionid,
-- for suspect links they're suspect.suspectid. SECURITY INVOKER, so you only
-- see links on incidents RLS already lets you see.
CREATE OR REPLACE FUNCTION public.incident_links()
  RETURNS TABLE (
    incident_a      integer,
    incident_b      integer,
    entitytype      varchar,
    matchconfidence numeric,
    verified        boolean
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  WITH ends AS (
    SELECT l.linkid, l.entitytype, l.matchconfidence,
           l.verificationstatus = 'verified' AS verified,
           CASE l.entitytype
             WHEN 'vehicle' THEN (SELECT m.incidentid
                                    FROM public.vehicledetail v
                                    JOIN public.detection d ON d.detectionid = v.detectionid
                                    JOIN public.media m ON m.mediaid = d.mediaid
                                   WHERE v.vehicledetectionid = l.entityid_a)
             ELSE (SELECT s.incidentid FROM public.suspect s WHERE s.suspectid = l.entityid_a)
           END AS ia,
           CASE l.entitytype
             WHEN 'vehicle' THEN (SELECT m.incidentid
                                    FROM public.vehicledetail v
                                    JOIN public.detection d ON d.detectionid = v.detectionid
                                    JOIN public.media m ON m.mediaid = d.mediaid
                                   WHERE v.vehicledetectionid = l.entityid_b)
             ELSE (SELECT s.incidentid FROM public.suspect s WHERE s.suspectid = l.entityid_b)
           END AS ib
    FROM public.crossreferencelink l
    WHERE l.verificationstatus <> 'rejected'
  )
  SELECT ia, ib, entitytype, matchconfidence, verified
  FROM ends
  WHERE ia IS NOT NULL AND ib IS NOT NULL AND ia <> ib
$$;


-- --- 4. list_submissions (replaces the 4-argument version)
--
--   p_order        'newest' (default) or 'oldest', by date reported
--   p_after_time   datereported of the last row you already have
--   p_after_id     and its incidentid. Together they're the page cursor.
--   p_limit        page size, default 30, capped at 100
--   p_search       incident number ('42', 'INC-0042') or location text
--   p_review       'pending' / 'accepted' / 'rejected' / 'duplicate'
--   p_caseid       only incidents in that case
--   p_locationkey  only that location group
--   p_ids          only these incidents (a linked group, suggestions)
--
-- Cursor paging instead of OFFSET, so page 50 is as quick as page 1. Every
-- page is just an index range scan.
DROP FUNCTION public.list_submissions(text, integer, text, integer);

CREATE FUNCTION public.list_submissions(
  p_search      text        DEFAULT NULL,
  p_limit       integer     DEFAULT 30,
  p_review      text        DEFAULT NULL,
  p_caseid      integer     DEFAULT NULL,
  p_order       text        DEFAULT 'newest',
  p_after_time  timestamptz DEFAULT NULL,
  p_after_id    integer     DEFAULT NULL,
  p_locationkey text        DEFAULT NULL,
  p_ids         integer[]   DEFAULT NULL
)
  RETURNS TABLE (
    incidentid      integer,
    location        text,
    datetime        timestamptz,
    attacktype      varchar,
    status          varchar,
    description     text,
    reportedby      integer,
    reportername    text,
    mediacount      integer,
    datereported    timestamptz,
    caseid          integer,
    casetitle       varchar,
    reviewstatus    varchar,
    reviewedat      timestamptz,
    reviewnote      text,
    duplicateof     integer,
    latitude        numeric,
    longitude       numeric,
    locationkey     text,
    aisummary       text,
    aisummarystatus varchar,
    aisummaryat     timestamptz,
    vehiclecount    integer,   -- max vehicles in any single clip
    personcount     integer,   -- max people in any single clip
    weaponcount     integer,   -- max weapons in any single clip
    plates          text[],    -- up to 3 distinct plates
    capturedat      timestamptz, -- earliest capture time from the footage
    timemismatch    boolean      -- capture time and typed time more than 3h apart
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  WITH t AS (
    SELECT raw,
           replace(replace(replace(raw, '\', '\\'), '%', '\%'), '_', '\_') AS term,
           CASE WHEN raw ~* '^(inc)?[\s#-]*[0-9]{1,9}$'
                THEN substring(raw FROM '[0-9]+')::integer END AS num,
           LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100) AS lim
    FROM (SELECT NULLIF(trim(COALESCE(p_search, '')), '') AS raw) q
  ),
  -- NOT MATERIALIZED so the filters get pushed into each page query and it
  -- can walk the (datereported, incidentid) index in order
  matches AS NOT MATERIALIZED (
    SELECT cs.*
    FROM public.crimescene cs CROSS JOIN t
    WHERE (t.raw IS NULL
           OR cs.incidentid = t.num
           OR cs.location ILIKE '%' || t.term || '%')
      AND (NULLIF(p_review, '') IS NULL OR cs.reviewstatus = p_review)
      AND (p_caseid IS NULL OR cs.caseid = p_caseid)
      AND (p_locationkey IS NULL OR cs.locationkey = p_locationkey)
      AND (p_ids IS NULL OR cs.incidentid = ANY (p_ids))
  ),
  -- only one of these two actually runs, the other's WHERE is false from the start
  page AS (
    (SELECT * FROM matches m
      WHERE COALESCE(p_order, 'newest') <> 'oldest'
        AND (m.datereported, m.incidentid)
          < (COALESCE(p_after_time, 'infinity'), COALESCE(p_after_id, 2147483647))
      ORDER BY m.datereported DESC, m.incidentid DESC
      LIMIT (SELECT lim FROM t))
    UNION ALL
    (SELECT * FROM matches m
      WHERE p_order = 'oldest'
        AND (m.datereported, m.incidentid)
          > (COALESCE(p_after_time, '-infinity'), COALESCE(p_after_id, 0))
      ORDER BY m.datereported ASC, m.incidentid ASC
      LIMIT (SELECT lim FROM t))
  )
  SELECT p.incidentid, p.location, p.datetime, p.attacktype, p.status,
         p.description, p.reportedby,
         NULLIF(trim(u.firstname || ' ' || u.surname), '') AS reportername,
         (SELECT count(*)::integer FROM public.media m
           WHERE m.incidentid = p.incidentid) AS mediacount,
         p.datereported, p.caseid, c.title AS casetitle,
         p.reviewstatus, p.reviewedat, p.reviewnote, p.duplicateof,
         p.latitude, p.longitude, p.locationkey,
         p.aisummary, p.aisummarystatus, p.aisummaryat,
         COALESCE(f.vehicles, 0), COALESCE(f.people, 0), COALESCE(f.weapons, 0),
         ARRAY(SELECT DISTINCT public.normalize_plate(v.licenceplatenumber)
                 FROM public.media m
                 JOIN public.detection d     ON d.mediaid = m.mediaid
                 JOIN public.vehicledetail v ON v.detectionid = d.detectionid
                WHERE m.incidentid = p.incidentid
                  AND public.normalize_plate(v.licenceplatenumber) IS NOT NULL
                ORDER BY 1
                LIMIT 3),
         cap.capturedat,
         COALESCE(abs(extract(epoch FROM cap.capturedat - p.datetime)) > 3 * 3600,
                  false)
  FROM page p
  LEFT JOIN public."User" u ON u.userid = p.reportedby
  LEFT JOIN LATERAL (
    SELECT min(m.capturetimestamp) AS capturedat
    FROM public.media m WHERE m.incidentid = p.incidentid
  ) cap ON true
  LEFT JOIN public.cases  c ON c.caseid = p.caseid
  LEFT JOIN LATERAL (
    SELECT max(per_clip.vehicles)::integer AS vehicles,
           max(per_clip.people)::integer   AS people,
           max(per_clip.weapons)::integer  AS weapons
    FROM (SELECT count(*) FILTER (WHERE d.detectiontype = 'vehicle') AS vehicles,
                 count(*) FILTER (WHERE d.detectiontype = 'person')  AS people,
                 count(*) FILTER (WHERE d.detectiontype = 'weapon')  AS weapons
            FROM public.media m
            JOIN public.detection d ON d.mediaid = m.mediaid
           WHERE m.incidentid = p.incidentid
           GROUP BY m.mediaid) per_clip
  ) f ON true
  ORDER BY
    CASE WHEN p_order = 'oldest' THEN p.datereported END ASC,
    CASE WHEN p_order = 'oldest' THEN p.incidentid  END ASC,
    p.datereported DESC, p.incidentid DESC
$$;

-- a submission's clips and what the AI saw in each one
CREATE OR REPLACE FUNCTION public.list_incident_media(p_incidentid integer)
  RETURNS TABLE (
    mediaid          integer,
    mediatype        varchar,
    storagepath      text,
    capturetimestamp timestamptz,
    uploadtimestamp  timestamptz,
    processingstatus varchar,
    aidescription    text,
    aidescribedat    timestamptz,
    detections       integer,
    verified         integer
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  SELECT m.mediaid, m.mediatype, m.storagepath, m.capturetimestamp,
         m.uploadtimestamp, m.processingstatus, m.aidescription, m.aidescribedat,
         (SELECT count(*)::integer FROM public.detection d WHERE d.mediaid = m.mediaid),
         (SELECT count(*)::integer FROM public.detection d
           WHERE d.mediaid = m.mediaid AND d.verified)
  FROM public.media m
  WHERE m.incidentid = p_incidentid
  ORDER BY COALESCE(m.capturetimestamp, m.uploadtimestamp), m.mediaid
$$;


-- --- 5. grouping

-- Locations, most recently reported first. label is whichever spelling is
-- most common in the group. Pass the locationkey to list_submissions to page
-- through one.
CREATE OR REPLACE FUNCTION public.list_location_groups(
  p_search text    DEFAULT NULL,
  p_review text    DEFAULT NULL,
  p_limit  integer DEFAULT 30,
  p_offset integer DEFAULT 0
)
  RETURNS TABLE (
    locationkey     text,
    label           text,
    submissioncount integer,
    pendingcount    integer,
    latestreported  timestamptz
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  WITH t AS (
    SELECT replace(replace(replace(NULLIF(trim(COALESCE(p_search, '')), ''),
             '\', '\\'), '%', '\%'), '_', '\_') AS term
  )
  SELECT cs.locationkey,
         mode() WITHIN GROUP (ORDER BY cs.location),
         count(*)::integer,
         (count(*) FILTER (WHERE cs.reviewstatus = 'pending'))::integer,
         max(cs.datereported)
  FROM public.crimescene cs CROSS JOIN t
  WHERE (t.term IS NULL OR cs.location ILIKE '%' || t.term || '%')
    AND (NULLIF(p_review, '') IS NULL OR cs.reviewstatus = p_review)
  GROUP BY cs.locationkey
  ORDER BY max(cs.datereported) DESC, cs.locationkey
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0)
$$;

-- Submissions joined up by cross-reference links (A-B plus B-C puts all
-- three in one group). Groups with something pending come first, then by
-- most recent.
CREATE OR REPLACE FUNCTION public.list_linked_groups(
  p_limit  integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
  RETURNS TABLE (
    groupid         integer,      -- lowest incident id in the group
    incidentids     integer[],
    submissioncount integer,
    pendingcount    integer,
    linkcount       integer,
    verifiedlinks   integer,
    bestconfidence  numeric,
    plates          text[],       -- plates seen in at least 2 of the group's submissions
    latestreported  timestamptz
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  WITH RECURSIVE
  links AS (SELECT * FROM public.incident_links()),
  edges AS (
    SELECT incident_a AS a, incident_b AS b FROM links
    UNION
    SELECT incident_b, incident_a FROM links
  ),
  -- every incident you can reach from each linked one
  reach (root, node) AS (
    SELECT a, a FROM edges
    UNION
    SELECT r.root, e.b FROM reach r JOIN edges e ON e.a = r.node
  ),
  groups AS (
    SELECT min(node) AS groupid, root AS incidentid
    FROM reach GROUP BY root
  ),
  members AS (
    SELECT g.groupid, cs.incidentid, cs.reviewstatus, cs.datereported
    FROM groups g JOIN public.crimescene cs ON cs.incidentid = g.incidentid
  ),
  plate_seen AS (
    SELECT mb.groupid, public.normalize_plate(v.licenceplatenumber) AS plate,
           count(DISTINCT mb.incidentid) AS incidents
    FROM members mb
    JOIN public.media m         ON m.incidentid = mb.incidentid
    JOIN public.detection d     ON d.mediaid = m.mediaid
    JOIN public.vehicledetail v ON v.detectionid = d.detectionid
    WHERE public.normalize_plate(v.licenceplatenumber) IS NOT NULL
    GROUP BY 1, 2
  )
  SELECT mb.groupid,
         array_agg(mb.incidentid ORDER BY mb.datereported DESC, mb.incidentid DESC),
         count(*)::integer,
         (count(*) FILTER (WHERE mb.reviewstatus = 'pending'))::integer,
         (SELECT count(*)::integer FROM links l
            JOIN groups g ON g.incidentid = l.incident_a
           WHERE g.groupid = mb.groupid),
         (SELECT count(*)::integer FROM links l
            JOIN groups g ON g.incidentid = l.incident_a
           WHERE g.groupid = mb.groupid AND l.verified),
         (SELECT max(l.matchconfidence) FROM links l
            JOIN groups g ON g.incidentid = l.incident_a
           WHERE g.groupid = mb.groupid),
         ARRAY(SELECT ps.plate FROM plate_seen ps
                WHERE ps.groupid = mb.groupid AND ps.incidents > 1
                ORDER BY ps.incidents DESC, ps.plate LIMIT 3),
         max(mb.datereported)
  FROM members mb
  GROUP BY mb.groupid
  ORDER BY (count(*) FILTER (WHERE mb.reviewstatus = 'pending') > 0) DESC,
           max(mb.datereported) DESC, mb.groupid
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
  OFFSET GREATEST(COALESCE(p_offset, 0), 0)
$$;

-- list_cases (replaces the 4-argument version). Now with paging, the lead
-- investigator, media/plate totals and a preview of the 3 newest
-- submissions, so a case card can show what's in it without opening it.
-- p_after_time / p_after_id are the lastactivity and caseid of the last
-- case you have.
DROP FUNCTION public.list_cases(text, text, integer, integer);

CREATE FUNCTION public.list_cases(
  p_search     text        DEFAULT NULL,
  p_status     text        DEFAULT NULL,
  p_limit      integer     DEFAULT 20,
  p_caseid     integer     DEFAULT NULL,
  p_after_time timestamptz DEFAULT NULL,
  p_after_id   integer     DEFAULT NULL
)
  RETURNS TABLE (
    caseid        integer,
    title         varchar,
    description   text,
    status        varchar,
    datecreated   timestamptz,
    dateclosed    timestamptz,
    createdbyname text,
    incidentcount integer,
    investigators jsonb,          -- active assignments: [{assignmentid, userid, name, badgenumber, islead}]
    lastactivity  timestamptz,
    mediacount    integer,
    plates        text[],
    preview       jsonb           -- the 3 newest: [{incidentid, location, datereported, reviewstatus, description, aisummary}]
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  WITH t AS (
    SELECT raw,
           replace(replace(replace(raw, '\', '\\'), '%', '\%'), '_', '\_') AS term,
           CASE WHEN raw ~* '^(case)?[\s#-]*[0-9]{1,9}$'
                THEN substring(raw FROM '[0-9]+')::integer END AS num
    FROM (SELECT NULLIF(trim(COALESCE(p_search, '')), '') AS raw) q
  ),
  base AS (
    SELECT c.*,
           GREATEST(c.datecreated,
                    (SELECT max(cs.reviewedat) FROM public.crimescene cs
                      WHERE cs.caseid = c.caseid),
                    (SELECT max(e.occurredat) FROM public.caseevent e
                      WHERE e.caseid = c.caseid)) AS lastactivity
    FROM public.cases c CROSS JOIN t
    WHERE (t.raw IS NULL OR c.caseid = t.num OR c.title ILIKE '%' || t.term || '%')
      AND (NULLIF(p_status, '') IS NULL
           OR (p_status = 'active' AND c.status IN ('open', 'under_review'))
           OR c.status = p_status)
      AND (p_caseid IS NULL OR c.caseid = p_caseid)
  ),
  page AS (
    SELECT * FROM base b
    WHERE p_after_time IS NULL
       OR (b.lastactivity, b.caseid) < (p_after_time, COALESCE(p_after_id, 2147483647))
    ORDER BY b.lastactivity DESC, b.caseid DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
  )
  SELECT b.caseid, b.title, b.description, b.status, b.datecreated, b.dateclosed,
         NULLIF(trim(u.firstname || ' ' || u.surname), ''),
         (SELECT count(*)::integer FROM public.crimescene cs WHERE cs.caseid = b.caseid),
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'assignmentid', ca.assignmentid,
                    'userid', iu.userid,
                    'name', concat_ws(' ', i.rank, iu.firstname, iu.surname),
                    'badgenumber', i.badgenumber,
                    'islead', ca.islead)
                  ORDER BY ca.islead DESC, ca.dateassigned)
           FROM public.caseassignment ca
           JOIN public."User" iu ON iu.userid = ca.assignedto
           LEFT JOIN public.investigator i ON i.userid = ca.assignedto
           WHERE ca.caseid = b.caseid AND ca.assignmentstatus = 'active'
         ), '[]'::jsonb),
         b.lastactivity,
         (SELECT count(*)::integer FROM public.media m
            JOIN public.crimescene cs ON cs.incidentid = m.incidentid
           WHERE cs.caseid = b.caseid),
         ARRAY(SELECT DISTINCT public.normalize_plate(v.licenceplatenumber)
                 FROM public.crimescene cs
                 JOIN public.media m         ON m.incidentid = cs.incidentid
                 JOIN public.detection d     ON d.mediaid = m.mediaid
                 JOIN public.vehicledetail v ON v.detectionid = d.detectionid
                WHERE cs.caseid = b.caseid
                  AND public.normalize_plate(v.licenceplatenumber) IS NOT NULL
                ORDER BY 1
                LIMIT 3),
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'incidentid', x.incidentid,
                    'location', x.location,
                    'datereported', x.datereported,
                    'reviewstatus', x.reviewstatus,
                    'description', x.description,
                    'aisummary', x.aisummary)
                  ORDER BY x.datereported DESC, x.incidentid DESC)
           FROM (SELECT cs.incidentid, cs.location, cs.datereported, cs.reviewstatus,
                        cs.description, cs.aisummary
                   FROM public.crimescene cs
                  WHERE cs.caseid = b.caseid
                  ORDER BY cs.datereported DESC, cs.incidentid DESC
                  LIMIT 3) x
         ), '[]'::jsonb)
  FROM page b
  LEFT JOIN public."User" u ON u.userid = b.createdby
  ORDER BY b.lastactivity DESC, b.caseid DESC
$$;


-- --- 6. suggestions
--
-- match_incidents scores every candidate against every target:
--   AI cross-reference link     verified +50 / pending +35
--   same plate                  +40, or one character off +25
--   within 5km (GPS)            +30, or same location text +20
--   within 2 hours              +30, or within 24 hours +10
--     (using incident_time, so footage capture time wins)
--   same vehicle colour + make  +10
-- Anything under 30 gets dropped, e.g. "same day" on its own isn't a reason.
-- The reasons are short strings the app shows as-is.
CREATE OR REPLACE FUNCTION public.match_incidents(
  p_candidates integer[],
  p_targets    integer[]
)
  RETURNS TABLE (
    candidateid integer,
    targetid    integer,
    score       integer,
    reasons     text[]
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  WITH
  inc AS (
    SELECT cs.incidentid, cs.latitude, cs.longitude, cs.locationkey,
           COALESCE(cap.t, cs.datetime) AS t,
           cap.t IS NOT NULL AS filmed       -- true if the time came from the footage
    FROM public.crimescene cs
    LEFT JOIN LATERAL (
      SELECT min(m.capturetimestamp) AS t
      FROM public.media m WHERE m.incidentid = cs.incidentid
    ) cap ON true
    WHERE cs.incidentid = ANY (p_candidates || p_targets)
  ),
  plates AS (
    SELECT DISTINCT m.incidentid, public.normalize_plate(v.licenceplatenumber) AS plate
    FROM public.media m
    JOIN public.detection d     ON d.mediaid = m.mediaid
    JOIN public.vehicledetail v ON v.detectionid = d.detectionid
    WHERE m.incidentid = ANY (p_candidates || p_targets)
      AND public.normalize_plate(v.licenceplatenumber) IS NOT NULL
  ),
  vehicles AS (
    SELECT DISTINCT m.incidentid,
           lower(trim(v.colour)) || ' ' || initcap(trim(v.make)) AS look
    FROM public.media m
    JOIN public.detection d     ON d.mediaid = m.mediaid
    JOIN public.vehicledetail v ON v.detectionid = d.detectionid
    WHERE m.incidentid = ANY (p_candidates || p_targets)
      AND NULLIF(trim(v.colour), '') IS NOT NULL
      AND NULLIF(trim(v.make), '') IS NOT NULL
  ),
  links AS (
    SELECT * FROM public.incident_links() l
    WHERE l.incident_a = ANY (p_candidates || p_targets)
      AND l.incident_b = ANY (p_candidates || p_targets)
  ),
  pairs AS (
    SELECT c.incidentid AS cid, t.incidentid AS tid,
           (SELECT bool_or(l.verified) FROM links l
             WHERE (l.incident_a, l.incident_b) IN ((c.incidentid, t.incidentid),
                                                    (t.incidentid, c.incidentid))) AS link_verified,
           (SELECT max(l.matchconfidence) FROM links l
             WHERE (l.incident_a, l.incident_b) IN ((c.incidentid, t.incidentid),
                                                    (t.incidentid, c.incidentid))) AS link_conf,
           (SELECT min(p1.plate) FROM plates p1
              JOIN plates p2 ON p2.plate = p1.plate
             WHERE p1.incidentid = c.incidentid AND p2.incidentid = t.incidentid) AS plate,
           (SELECT min(p1.plate || ' / ' || p2.plate) FROM plates p1
              JOIN plates p2 ON public.plates_similar(p1.plate, p2.plate)
             WHERE p1.incidentid = c.incidentid AND p2.incidentid = t.incidentid) AS nearplate,
           CASE WHEN c.latitude IS NOT NULL AND t.latitude IS NOT NULL
                THEN public.distance_km(c.latitude, c.longitude, t.latitude, t.longitude)
           END AS km,
           c.locationkey = t.locationkey AS same_place,
           abs(extract(epoch FROM c.t - t.t)) / 60 AS minutes,
           c.filmed AND t.filmed AS both_filmed,
           (SELECT min(v1.look) FROM vehicles v1
              JOIN vehicles v2 ON v2.look = v1.look
             WHERE v1.incidentid = c.incidentid AND v2.incidentid = t.incidentid) AS look
    FROM inc c
    JOIN inc t ON t.incidentid = ANY (p_targets) AND t.incidentid <> c.incidentid
    WHERE c.incidentid = ANY (p_candidates)
  ),
  scored AS (
    SELECT p.*,
           CASE WHEN p.link_verified THEN 50
                WHEN p.link_verified IS NOT NULL THEN 35 ELSE 0 END
         + CASE WHEN p.plate IS NOT NULL THEN 40
                WHEN p.nearplate IS NOT NULL THEN 25 ELSE 0 END
         + CASE WHEN p.km IS NOT NULL AND p.km <= 5 THEN 30
                WHEN (p.km IS NULL OR p.km > 5) AND p.same_place THEN 20 ELSE 0 END
         + CASE WHEN p.minutes <= 120 THEN 30
                WHEN p.minutes <= 1440 THEN 10 ELSE 0 END
         + CASE WHEN p.look IS NOT NULL THEN 10 ELSE 0 END AS total
    FROM pairs p
  )
  SELECT s.cid, s.tid, s.total,
         array_remove(ARRAY[
           CASE WHEN s.link_verified THEN 'Verified AI link'
                WHEN s.link_verified IS NOT NULL
                  THEN 'AI link' || COALESCE(' (' || round(s.link_conf * 100) || '% match)', '')
           END,
           CASE WHEN s.plate IS NOT NULL THEN 'Same plate ' || s.plate
                WHEN s.nearplate IS NOT NULL
                  THEN 'Similar plate ' || s.nearplate || ' (1 character different)'
           END,
           CASE WHEN s.km IS NOT NULL AND s.km <= 5
                  THEN CASE WHEN s.km < 1 THEN round(s.km * 1000) || ' m apart'
                            ELSE round(s.km, 1) || ' km apart' END
                WHEN s.same_place THEN 'Same location'
           END,
           CASE WHEN s.minutes <= 120
                  THEN CASE WHEN s.minutes < 1 THEN 'Same time'
                            ELSE round(s.minutes) || ' min apart' END
                       || CASE WHEN s.both_filmed THEN ' (video time)' ELSE '' END
                WHEN s.minutes <= 1440
                  THEN round(s.minutes / 60) || ' h apart'
                       || CASE WHEN s.both_filmed THEN ' (video time)' ELSE '' END
           END,
           CASE WHEN s.look IS NOT NULL THEN 'Both show a ' || s.look END
         ], NULL)
  FROM scored s
  WHERE s.total >= 30
$$;

-- Pending submissions that probably belong in this case, best first. To keep
-- it quick we only compare ones within 14 days of a case incident, or ones
-- that are linked to or share a plate with one.
CREATE OR REPLACE FUNCTION public.suggest_incidents_for_case(
  p_caseid integer,
  p_limit  integer DEFAULT 5
)
  RETURNS TABLE (
    incidentid        integer,
    score             integer,
    reasons           text[],
    matchedincidentid integer      -- which incident in the case it matched best
  )
  LANGUAGE plpgsql STABLE
  SET search_path = ''
AS $$
DECLARE
  v_targets    integer[];
  v_candidates integer[];
BEGIN
  PERFORM public.require_admin();

  SELECT array_agg(cs.incidentid) INTO v_targets
  FROM public.crimescene cs WHERE cs.caseid = p_caseid;
  IF v_targets IS NULL THEN
    RETURN;                                -- empty case, nothing to compare against
  END IF;

  SELECT array_agg(DISTINCT c.incidentid) INTO v_candidates
  FROM public.crimescene c
  WHERE c.reviewstatus = 'pending'
    AND (
      EXISTS (SELECT 1 FROM unnest(v_targets) AS t(id)
               WHERE public.incident_time(c.incidentid)
                     BETWEEN public.incident_time(t.id) - interval '14 days'
                         AND public.incident_time(t.id) + interval '14 days')
      OR EXISTS (SELECT 1 FROM public.incident_links() l
                  WHERE (l.incident_a = c.incidentid AND l.incident_b = ANY (v_targets))
                     OR (l.incident_b = c.incidentid AND l.incident_a = ANY (v_targets)))
      OR EXISTS (SELECT 1
                   FROM public.media m1
                   JOIN public.detection d1     ON d1.mediaid = m1.mediaid
                   JOIN public.vehicledetail v1 ON v1.detectionid = d1.detectionid
                   JOIN public.vehicledetail v2
                     ON public.normalize_plate(v2.licenceplatenumber)
                      = public.normalize_plate(v1.licenceplatenumber)
                   JOIN public.detection d2 ON d2.detectionid = v2.detectionid
                   JOIN public.media m2     ON m2.mediaid = d2.mediaid
                  WHERE m1.incidentid = c.incidentid
                    AND m2.incidentid = ANY (v_targets)
                    AND public.normalize_plate(v1.licenceplatenumber) IS NOT NULL)
    );
  IF v_candidates IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT best.candidateid, best.score, best.reasons, best.targetid
  FROM (
    SELECT DISTINCT ON (mi.candidateid) mi.*
    FROM public.match_incidents(v_candidates, v_targets) mi
    ORDER BY mi.candidateid, mi.score DESC, mi.targetid
  ) best
  JOIN public.crimescene cs ON cs.incidentid = best.candidateid
  ORDER BY best.score DESC, cs.datereported DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 5), 1), 20);
END;
$$;

-- Open/under-review cases this submission probably belongs to, best first.
-- Used for "Add to an existing case".
CREATE OR REPLACE FUNCTION public.suggest_cases_for_incident(
  p_incidentid integer,
  p_limit      integer DEFAULT 3
)
  RETURNS TABLE (
    caseid            integer,
    score             integer,
    reasons           text[],
    matchedincidentid integer      -- which incident in that case it matched best
  )
  LANGUAGE plpgsql STABLE
  SET search_path = ''
AS $$
DECLARE
  v_candidates integer[];
BEGIN
  PERFORM public.require_admin();

  SELECT array_agg(cs.incidentid) INTO v_candidates
  FROM public.crimescene cs
  JOIN public.cases c ON c.caseid = cs.caseid
  WHERE c.status IN ('open', 'under_review')
    AND cs.incidentid <> p_incidentid;
  IF v_candidates IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT best.caseid, best.score, best.reasons, best.candidateid
  FROM (
    SELECT DISTINCT ON (cs.caseid) cs.caseid, mi.candidateid, mi.score, mi.reasons
    FROM public.match_incidents(v_candidates, ARRAY[p_incidentid]) mi
    JOIN public.crimescene cs ON cs.incidentid = mi.candidateid
    ORDER BY cs.caseid, mi.score DESC, mi.candidateid
  ) best
  ORDER BY best.score DESC, best.caseid DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 3), 1), 10);
END;
$$;


-- --- 6b. one-tap review of suggested matches
--
-- list_suggested_matches gives pending submissions that match an open case
-- well enough (score >= 60, "likely" or better), each with its single best
-- case. The admin unticks anything wrong and accepts the rest in one go with
-- accept_suggested_matches.
--
-- Only looks at submissions from the last 30 days, against case incidents
-- within 14 days of them, to keep it fast.
CREATE OR REPLACE FUNCTION public.list_suggested_matches(
  p_minscore integer DEFAULT 60,
  p_limit    integer DEFAULT 50
)
  RETURNS TABLE (
    incidentid        integer,
    caseid            integer,
    score             integer,
    reasons           text[],
    matchedincidentid integer,     -- which incident in that case it matched best
    othercases        integer      -- how many other cases also scored >= p_minscore
  )
  LANGUAGE plpgsql STABLE
  SET search_path = ''
AS $$
DECLARE
  v_pending integer[];
  v_targets integer[];
BEGIN
  PERFORM public.require_admin();

  SELECT array_agg(cs.incidentid) INTO v_pending
  FROM public.crimescene cs
  WHERE cs.reviewstatus = 'pending'
    AND cs.datereported >= now() - interval '30 days';
  IF v_pending IS NULL THEN
    RETURN;
  END IF;

  WITH pending_times AS (
    SELECT public.incident_time(id) AS t FROM unnest(v_pending) AS p(id)
  )
  SELECT array_agg(t.incidentid) INTO v_targets
  FROM public.crimescene t
  JOIN public.cases c ON c.caseid = t.caseid
  WHERE c.status IN ('open', 'under_review')
    AND EXISTS (SELECT 1 FROM pending_times p
                 WHERE public.incident_time(t.incidentid)
                       BETWEEN p.t - interval '14 days' AND p.t + interval '14 days');
  IF v_targets IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH per_case AS (
    -- best score for each (submission, case) pair
    SELECT DISTINCT ON (mi.candidateid, t.caseid)
           mi.candidateid, t.caseid, mi.score, mi.reasons, mi.targetid
    FROM public.match_incidents(v_pending, v_targets) mi
    JOIN public.crimescene t ON t.incidentid = mi.targetid
    WHERE mi.score >= p_minscore
    ORDER BY mi.candidateid, t.caseid, mi.score DESC, mi.targetid
  ),
  ranked AS (
    SELECT pc.*,
           row_number() OVER (PARTITION BY pc.candidateid
                              ORDER BY pc.score DESC, pc.caseid DESC) AS rn,
           count(*)     OVER (PARTITION BY pc.candidateid) AS cases
    FROM per_case pc
  )
  SELECT r.candidateid, r.caseid, r.score, r.reasons, r.targetid,
         (r.cases - 1)::integer
  FROM ranked r
  JOIN public.crimescene cs ON cs.incidentid = r.candidateid
  WHERE r.rn = 1
  ORDER BY r.score DESC, cs.datereported DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200);
END;
$$;

-- Accept the ticked matches in one transaction, p_incidentids[i] goes into
-- p_caseids[i]. If someone else already reviewed a submission, or the case
-- got closed in the meantime, we skip it rather than fail. Returns how many
-- were added.
CREATE OR REPLACE FUNCTION public.accept_suggested_matches(
  p_incidentids integer[],
  p_caseids     integer[]
)
  RETURNS integer
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
DECLARE
  v_added integer := 0;
  i       integer;
BEGIN
  PERFORM public.require_admin();
  IF COALESCE(cardinality(p_incidentids), 0) <> COALESCE(cardinality(p_caseids), 0) THEN
    RAISE EXCEPTION 'Each submission needs exactly one case';
  END IF;

  FOR i IN 1 .. COALESCE(cardinality(p_incidentids), 0) LOOP
    IF EXISTS (SELECT 1 FROM public.crimescene
                WHERE incidentid = p_incidentids[i] AND reviewstatus = 'pending')
       AND EXISTS (SELECT 1 FROM public.cases
                    WHERE caseid = p_caseids[i] AND status <> 'closed')
    THEN
      PERFORM public.attach_incident(p_incidentids[i], p_caseids[i]);
      v_added := v_added + 1;
    END IF;
  END LOOP;
  RETURN v_added;
END;
$$;


-- --- 7. privileges
REVOKE EXECUTE ON FUNCTION public.protect_crimescene_ai()     FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.protect_media_ai()          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.mark_ai_summary_outdated()  FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.normalize_plate(text)                              FROM anon;
REVOKE EXECUTE ON FUNCTION public.plates_similar(text, text)                         FROM anon;
REVOKE EXECUTE ON FUNCTION public.incident_time(integer)                             FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.incident_time(integer)                             TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.distance_km(numeric, numeric, numeric, numeric)    FROM anon;
REVOKE EXECUTE ON FUNCTION public.incident_links()                                   FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.list_submissions(text, integer, text, integer, text, timestamptz, integer, text, integer[]) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.list_incident_media(integer)                       FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.list_location_groups(text, text, integer, integer) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.list_linked_groups(integer, integer)               FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.list_cases(text, text, integer, integer, timestamptz, integer) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.match_incidents(integer[], integer[])              FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.suggest_incidents_for_case(integer, integer)       FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.suggest_cases_for_incident(integer, integer)       FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.incident_links()                                   TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_submissions(text, integer, text, integer, text, timestamptz, integer, text, integer[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_incident_media(integer)                       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_location_groups(text, text, integer, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_linked_groups(integer, integer)               TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_cases(text, text, integer, integer, timestamptz, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.match_incidents(integer[], integer[])              TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.suggest_incidents_for_case(integer, integer)       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.suggest_cases_for_incident(integer, integer)       TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.list_suggested_matches(integer, integer)          FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.accept_suggested_matches(integer[], integer[])    FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.list_suggested_matches(integer, integer)          TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.accept_suggested_matches(integer[], integer[])    TO authenticated, service_role;
