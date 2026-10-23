-- Suspect review (POPIA) and richer case cards.
--
-- Under POPIA someone who shows up in footage isn't a suspect until an
-- investigator on the case has actually looked at them. So:
--
-- Every person detection now has a suspect status:
--   possible   the AI saw a person, nobody has reviewed them
--   confirmed  an investigator confirmed them (there's a suspect row)
--   dismissed  an investigator ruled them out (bystander, guard...), with a
--              reason
-- New person detections always start as 'possible' and the AI pipeline can't
-- confirm or dismiss anyone.
--
-- Only an investigator actively assigned to the case can confirm/dismiss or
-- edit a confirmed suspect's descriptions. Admins can't create, edit or
-- delete suspects any more. An admin or an investigator on the case can undo
-- a review (with a reason), which deletes the suspect record (data
-- minimisation) and puts the person back to 'possible'.
--
-- Every decision goes into the case history (caseevent) via a trigger, and
-- nothing in caseevent can be changed from the app.
--
-- Case and submission cards get possible/confirmed suspect counts, using
-- the same "most seen at once in one clip" rule as the other counts. For
-- cases it's the highest of its submissions (A = 2, B = 1, C = 1 gives
-- "about 2"). Only counts go out here, never descriptions of possible
-- suspects.
--
-- case_card_suggestions gives each case card its best suggested pending
-- submission and the most relevant plate in it.


-- --- 1. suspect status on detection
ALTER TABLE public.detection
  ADD COLUMN suspectstatus     varchar(20),
  ADD COLUMN suspectreviewedby integer REFERENCES public."User" (userid),
  ADD COLUMN suspectreviewedat timestamptz,
  ADD COLUMN suspectreviewnote text;

-- Backfill: person detections that already have a suspect row are
-- confirmed, the rest are possible.
UPDATE public.detection d
   SET suspectstatus     = CASE WHEN s.suspectid IS NOT NULL THEN 'confirmed' ELSE 'possible' END,
       suspectreviewedby = s.confirmedby,
       suspectreviewedat = CASE WHEN s.suspectid IS NOT NULL
                                THEN COALESCE(s.dateconfirmed, now()) END
  FROM public.detection d2
  LEFT JOIN public.suspect s ON s.detectionid = d2.detectionid
 WHERE d.detectionid = d2.detectionid
   AND d.detectiontype = 'person';

ALTER TABLE public.detection
  -- only people have a suspect status, and they always have one
  ADD CONSTRAINT detection_suspectstatus_type_check
    CHECK ((detectiontype = 'person') = (suspectstatus IS NOT NULL)),
  ADD CONSTRAINT detection_suspectstatus_check
    CHECK (suspectstatus IN ('possible', 'confirmed', 'dismissed')),
  -- 'possible' means unreviewed, so no reviewer, time or note
  ADD CONSTRAINT detection_suspectreview_check
    CHECK (CASE WHEN suspectstatus = 'possible'
                THEN suspectreviewedby IS NULL AND suspectreviewedat IS NULL
                     AND suspectreviewnote IS NULL
                WHEN suspectstatus IN ('confirmed', 'dismissed')
                THEN suspectreviewedat IS NOT NULL
                ELSE true END),
  -- you have to say why when dismissing
  ADD CONSTRAINT detection_suspectdismiss_check
    CHECK (suspectstatus IS DISTINCT FROM 'dismissed'
           OR NULLIF(trim(suspectreviewnote), '') IS NOT NULL),
  ADD CONSTRAINT detection_suspectreviewnote_check
    CHECK (char_length(suspectreviewnote) <= 500);

CREATE INDEX idx_detection_suspectreviewedby ON public.detection (suspectreviewedby);
-- for counting possible/confirmed people per clip
CREATE INDEX idx_detection_media_person
  ON public.detection (mediaid, suspectstatus) WHERE detectiontype = 'person';

-- New person detections start as 'possible', other types never get a status.
-- Only the review functions below can change it, both the app
-- (authenticated) and the pipeline (service_role) get refused. Those
-- functions are SECURITY DEFINER, so inside them current_user is the owner
-- and they get through this check.
CREATE OR REPLACE FUNCTION public.protect_detection_suspect()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
DECLARE
  v_restricted boolean := current_user IN ('authenticated', 'anon', 'service_role');
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.detectiontype <> 'person' THEN
      NEW.suspectstatus := NULL;
    ELSIF NEW.suspectstatus IS NULL OR v_restricted THEN
      NEW.suspectstatus := 'possible';
      NEW.suspectreviewedby := NULL;
      NEW.suspectreviewedat := NULL;
      NEW.suspectreviewnote := NULL;
    END IF;
    RETURN NEW;
  END IF;

  IF v_restricted AND (
       NEW.suspectstatus     IS DISTINCT FROM OLD.suspectstatus
    OR NEW.suspectreviewedby IS DISTINCT FROM OLD.suspectreviewedby
    OR NEW.suspectreviewedat IS DISTINCT FROM OLD.suspectreviewedat
    OR NEW.suspectreviewnote IS DISTINCT FROM OLD.suspectreviewnote
    OR (NEW.detectiontype IS DISTINCT FROM OLD.detectiontype
        AND (NEW.detectiontype = 'person' OR OLD.detectiontype = 'person')))
  THEN
    RAISE EXCEPTION 'Suspects are confirmed or dismissed by an investigator on the case only'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_detection_suspect
  BEFORE INSERT OR UPDATE ON public.detection
  FOR EACH ROW EXECUTE FUNCTION public.protect_detection_suspect();


-- --- 2. suspect rules and RLS
-- a suspect has to be a person detection from the same incident
CREATE OR REPLACE FUNCTION public.check_suspect()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
DECLARE
  v_type       text;
  v_incidentid integer;
BEGIN
  SELECT d.detectiontype, m.incidentid INTO v_type, v_incidentid
  FROM public.detection d
  JOIN public.media m ON m.mediaid = d.mediaid
  WHERE d.detectionid = NEW.detectionid;

  IF v_type IS DISTINCT FROM 'person' THEN
    RAISE EXCEPTION 'Detection % is not a person detection', NEW.detectionid;
  END IF;
  IF v_incidentid IS DISTINCT FROM NEW.incidentid THEN
    RAISE EXCEPTION 'Detection % is not part of incident %', NEW.detectionid, NEW.incidentid;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER check_suspect
  BEFORE INSERT OR UPDATE OF detectionid, incidentid ON public.suspect
  FOR EACH ROW EXECUTE FUNCTION public.check_suspect();

-- Suspects are only written by the functions below from now on. Admins can
-- still read them (oversight), investigators see the ones on their cases.
DROP POLICY IF EXISTS "suspect_insert" ON public.suspect;
DROP POLICY IF EXISTS "suspect_update" ON public.suspect;
DROP POLICY IF EXISTS "suspect_delete" ON public.suspect;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.suspect FROM anon, authenticated;


-- --- 3. review functions
-- SECURITY DEFINER because the app can't write detection or suspect
-- directly, these functions do the who-are-you checks instead.

-- Fetch and lock a person detection along with its incident and case.
-- Raises if it isn't a person.
CREATE OR REPLACE FUNCTION public.person_detection_context(
  p_detectionid integer,
  OUT incidentid    integer,
  OUT caseid        integer,
  OUT casestatus    text,
  OUT suspectstatus text
)
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  SELECT m.incidentid, cs.caseid, c.status, d.suspectstatus
    INTO incidentid, caseid, casestatus, suspectstatus
  FROM public.detection d
  JOIN public.media m       ON m.mediaid = d.mediaid
  JOIN public.crimescene cs ON cs.incidentid = m.incidentid
  LEFT JOIN public.cases c  ON c.caseid = cs.caseid
  WHERE d.detectionid = p_detectionid
    AND d.detectiontype = 'person'
  FOR UPDATE OF d;

  IF incidentid IS NULL THEN
    RAISE EXCEPTION 'Person detection % not found', p_detectionid;
  END IF;
END;
$$;

-- Confirm or dismiss a possible suspect. Investigators actively assigned to
-- the case only, and not on closed cases.
--   p_decision  'confirmed' or 'dismissed'
--   p_note      the reason, required for a dismissal
--   p_physical / p_clothing  descriptions, for a confirmed suspect
-- Returns the new suspectid when confirming, otherwise NULL.
CREATE OR REPLACE FUNCTION public.review_possible_suspect(
  p_detectionid integer,
  p_decision    text,
  p_note        text DEFAULT NULL,
  p_physical    text DEFAULT NULL,
  p_clothing    text DEFAULT NULL
)
  RETURNS integer
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_ctx  record;
  v_me   integer := public.current_user_id();
  v_note text    := NULLIF(trim(COALESCE(p_note, '')), '');
  v_id   integer;
BEGIN
  IF p_decision IS NULL OR p_decision NOT IN ('confirmed', 'dismissed') THEN
    RAISE EXCEPTION 'Decision must be confirmed or dismissed';
  END IF;
  IF public.current_user_role() IS DISTINCT FROM 'investigator' THEN
    RAISE EXCEPTION 'Only an investigator assigned to the case can review suspects'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_ctx FROM public.person_detection_context(p_detectionid);

  IF v_ctx.caseid IS NULL OR NOT public.is_assigned_to_case(v_ctx.caseid) THEN
    RAISE EXCEPTION 'Only an investigator assigned to the case can review suspects'
      USING ERRCODE = '42501';
  END IF;
  IF v_ctx.casestatus = 'closed' THEN
    RAISE EXCEPTION 'Case % is closed', v_ctx.caseid;
  END IF;
  IF v_ctx.suspectstatus <> 'possible' THEN
    RAISE EXCEPTION 'This person was already reviewed (%); undo that review first',
      v_ctx.suspectstatus;
  END IF;
  IF p_decision = 'dismissed' AND v_note IS NULL THEN
    RAISE EXCEPTION 'Give a reason for dismissing this person';
  END IF;

  IF p_decision = 'confirmed' THEN
    INSERT INTO public.suspect (detectionid, incidentid, physicaldescription,
                                clothingdescription, confirmedby, dateconfirmed)
    VALUES (p_detectionid, v_ctx.incidentid,
            NULLIF(trim(COALESCE(p_physical, '')), ''),
            NULLIF(trim(COALESCE(p_clothing, '')), ''),
            v_me, now())
    RETURNING suspectid INTO v_id;
  END IF;

  UPDATE public.detection
     SET suspectstatus     = p_decision,
         suspectreviewedby = v_me,
         suspectreviewedat = now(),
         suspectreviewnote = v_note
   WHERE detectionid = p_detectionid;

  RETURN v_id;
END;
$$;

-- Edit a confirmed suspect's descriptions. Investigators on the case only,
-- not on closed cases. Only the values you pass get changed.
CREATE OR REPLACE FUNCTION public.update_suspect_details(
  p_suspectid integer,
  p_physical  text DEFAULT NULL,
  p_clothing  text DEFAULT NULL
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_caseid integer;
  v_status text;
BEGIN
  SELECT cs.caseid, c.status INTO v_caseid, v_status
  FROM public.suspect s
  JOIN public.crimescene cs ON cs.incidentid = s.incidentid
  LEFT JOIN public.cases c  ON c.caseid = cs.caseid
  WHERE s.suspectid = p_suspectid;

  IF public.current_user_role() IS DISTINCT FROM 'investigator'
     OR v_caseid IS NULL OR NOT public.is_assigned_to_case(v_caseid) THEN
    RAISE EXCEPTION 'Only an investigator assigned to the case can edit suspects'
      USING ERRCODE = '42501';
  END IF;
  IF v_status = 'closed' THEN
    RAISE EXCEPTION 'Case % is closed', v_caseid;
  END IF;

  UPDATE public.suspect
     SET physicaldescription = CASE WHEN p_physical IS NULL THEN physicaldescription
                                    ELSE NULLIF(trim(p_physical), '') END,
         clothingdescription = CASE WHEN p_clothing IS NULL THEN clothingdescription
                                    ELSE NULLIF(trim(p_clothing), '') END
   WHERE suspectid = p_suspectid;
END;
$$;

-- Undo a confirm or dismiss and put the person back to 'possible'. For a
-- confirmed suspect we delete the record, since their descriptions are
-- personal info we no longer need. Weapons stop pointing at them and AI
-- links to them get rejected. The case history keeps who undid it, when and
-- why. Admins or an investigator on the case, reason required.
CREATE OR REPLACE FUNCTION public.undo_suspect_review(
  p_detectionid integer,
  p_reason      text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_ctx       record;
  v_role      text := public.current_user_role();
  v_reason    text := NULLIF(trim(COALESCE(p_reason, '')), '');
  v_suspectid integer;
BEGIN
  SELECT * INTO v_ctx FROM public.person_detection_context(p_detectionid);

  IF NOT (v_role = 'admin'
          OR (v_role = 'investigator' AND v_ctx.caseid IS NOT NULL
              AND public.is_assigned_to_case(v_ctx.caseid))) THEN
    RAISE EXCEPTION 'You are not allowed to change this review' USING ERRCODE = '42501';
  END IF;
  IF v_ctx.suspectstatus = 'possible' THEN
    RAISE EXCEPTION 'This person has not been reviewed yet';
  END IF;
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Give a reason for undoing this review';
  END IF;

  SELECT s.suspectid INTO v_suspectid FROM public.suspect s
   WHERE s.detectionid = p_detectionid;
  IF v_suspectid IS NOT NULL THEN
    UPDATE public.crossreferencelink
       SET verificationstatus = 'rejected'
     WHERE entitytype = 'suspect'
       AND v_suspectid IN (entityid_a, entityid_b)
       AND verificationstatus <> 'rejected';
    DELETE FROM public.suspect WHERE suspectid = v_suspectid;  -- sets weapondetail.suspectid to NULL
  END IF;

  -- the reason gets to the history via the note, the trigger reads it
  -- before the row is reset
  PERFORM set_config('argus.undo_reason', v_reason, true);
  UPDATE public.detection
     SET suspectstatus     = 'possible',
         suspectreviewedby = NULL,
         suspectreviewedat = NULL,
         suspectreviewnote = NULL
   WHERE detectionid = p_detectionid;
  PERFORM set_config('argus.undo_reason', '', true);
END;
$$;


-- --- 4. case history: every review ends up in caseevent
ALTER TABLE public.caseevent DROP CONSTRAINT caseevent_eventtype_check;
ALTER TABLE public.caseevent ADD CONSTRAINT caseevent_eventtype_check
  CHECK (eventtype IN (
    'submitted', 'added_to_case', 'removed_from_case', 'rejected', 'duplicate',
    'reopened', 'case_created', 'case_edited', 'status_changed', 'case_deleted',
    'assigned', 'unassigned', 'lead_changed',
    'detection_verified', 'detection_unverified',
    'suspect_confirmed',
    'suspect_dismissed',      -- always has a reason
    'suspect_review_undone',  -- back to possible, always has a reason
    'suspect_edited'));

CREATE OR REPLACE FUNCTION public.log_suspect_review_event()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_incidentid integer;
  v_caseid     integer;
  v_person     text := 'person P-' || lpad(NEW.detectionid::text, 3, '0');
BEGIN
  SELECT m.incidentid, cs.caseid INTO v_incidentid, v_caseid
  FROM public.media m
  JOIN public.crimescene cs ON cs.incidentid = m.incidentid
  WHERE m.mediaid = NEW.mediaid;

  IF NEW.suspectstatus = 'possible' THEN
    PERFORM public.log_case_event('suspect_review_undone', v_caseid, v_incidentid,
      v_person || ' was ' || OLD.suspectstatus
      || COALESCE(': ' || NULLIF(current_setting('argus.undo_reason', true), ''), ''));
  ELSE
    PERFORM public.log_case_event(
      CASE NEW.suspectstatus WHEN 'confirmed' THEN 'suspect_confirmed'
                             ELSE 'suspect_dismissed' END,
      v_caseid, v_incidentid,
      v_person || COALESCE(': ' || NEW.suspectreviewnote, ''));
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER log_suspect_review_event
  AFTER UPDATE OF suspectstatus ON public.detection
  FOR EACH ROW
  WHEN (NEW.suspectstatus IS DISTINCT FROM OLD.suspectstatus)
  EXECUTE FUNCTION public.log_suspect_review_event();

-- Edits get logged without the actual descriptions. The history is about who
-- changed what, it shouldn't be a second copy of personal data.
CREATE OR REPLACE FUNCTION public.log_suspect_edit_event()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_caseid integer;
BEGIN
  SELECT cs.caseid INTO v_caseid FROM public.crimescene cs
   WHERE cs.incidentid = NEW.incidentid;
  PERFORM public.log_case_event('suspect_edited', v_caseid, NEW.incidentid,
    'suspect S-' || lpad(NEW.suspectid::text, 3, '0') || ': '
    || concat_ws(' and ',
         CASE WHEN NEW.physicaldescription IS DISTINCT FROM OLD.physicaldescription
              THEN 'physical description' END,
         CASE WHEN NEW.clothingdescription IS DISTINCT FROM OLD.clothingdescription
              THEN 'clothing description' END)
    || ' changed');
  RETURN NEW;
END;
$$;

CREATE TRIGGER log_suspect_edit_event
  AFTER UPDATE OF physicaldescription, clothingdescription ON public.suspect
  FOR EACH ROW
  WHEN (NEW.physicaldescription IS DISTINCT FROM OLD.physicaldescription
        OR NEW.clothingdescription IS DISTINCT FROM OLD.clothingdescription)
  EXECUTE FUNCTION public.log_suspect_edit_event();


-- --- 5. list_submissions, now with possiblesuspects/confirmedsuspects
-- (the return type changes, so drop and recreate)
DROP FUNCTION public.list_submissions(text, integer, text, integer, text, timestamptz, integer, text, integer[]);

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
    timemismatch    boolean,     -- capture time and typed time more than 3h apart
    possiblesuspects  integer,   -- max unreviewed people in any single clip
    confirmedsuspects integer    -- max confirmed suspects in any single clip
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
                  false),
         COALESCE(f.possible, 0), COALESCE(f.confirmed, 0)
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
           max(per_clip.weapons)::integer  AS weapons,
           max(per_clip.possible)::integer  AS possible,
           max(per_clip.confirmed)::integer AS confirmed
    FROM (SELECT count(*) FILTER (WHERE d.detectiontype = 'vehicle') AS vehicles,
                 count(*) FILTER (WHERE d.detectiontype = 'person')  AS people,
                 count(*) FILTER (WHERE d.detectiontype = 'weapon')  AS weapons,
                 count(*) FILTER (WHERE d.suspectstatus = 'possible')  AS possible,
                 count(*) FILTER (WHERE d.suspectstatus = 'confirmed') AS confirmed
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


-- --- 6. list_cases, now with possiblesuspects/confirmedsuspects
-- (the return type changes, so drop and recreate)
DROP FUNCTION public.list_cases(text, text, integer, integer, timestamptz, integer);

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
    preview       jsonb,          -- the 3 newest: [{incidentid, location, datereported, reviewstatus, description, aisummary}]
    possiblesuspects  integer,    -- highest across the case's submissions
    confirmedsuspects integer     -- same
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
         ), '[]'::jsonb),
         COALESCE(sus.possible, 0), COALESCE(sus.confirmed, 0)
  FROM page b
  LEFT JOIN public."User" u ON u.userid = b.createdby
  -- per clip first, then the highest clip across the case's submissions
  LEFT JOIN LATERAL (
    SELECT max(per_clip.possible)::integer  AS possible,
           max(per_clip.confirmed)::integer AS confirmed
    FROM (SELECT count(*) FILTER (WHERE d.suspectstatus = 'possible')  AS possible,
                 count(*) FILTER (WHERE d.suspectstatus = 'confirmed') AS confirmed
            FROM public.crimescene cs
            JOIN public.media m     ON m.incidentid = cs.incidentid
            JOIN public.detection d ON d.mediaid = m.mediaid
           WHERE cs.caseid = b.caseid
             AND d.detectiontype = 'person'
           GROUP BY m.mediaid) per_clip
  ) sus ON true
  ORDER BY b.lastactivity DESC, b.caseid DESC
$$;


-- --- 7. case_card_suggestions
--
-- For the Cases tab: each case's best suggested pending submission (same
-- scoring as suggest_incidents_for_case), how many others got suggested,
-- and the most useful plate the AI read in it. "Most useful" means a plate
-- that's also in the case, else one that's a character off one in the case
-- (probably a misread), else whichever read was most confident. The app
-- marks these as unconfirmed AI reads.
-- Skips closed cases since they can't take new submissions. Called once per
-- page of cards, max 50 cases a call.
CREATE OR REPLACE FUNCTION public.case_card_suggestions(p_caseids integer[])
  RETURNS TABLE (
    caseid       integer,
    incidentid   integer,     -- best suggested pending submission
    score        integer,
    reasons      text[],
    othercount   integer,     -- how many others were suggested too
    plate        text,        -- most relevant plate, NULL if none was read
    platematch   text         -- 'same' / 'similar' to a plate in the case, or NULL
  )
  LANGUAGE plpgsql STABLE
  SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_caseid integer;
BEGIN
  PERFORM public.require_admin();

  FOR v_caseid IN
    SELECT c.caseid FROM public.cases c
    WHERE c.caseid = ANY ((COALESCE(p_caseids, '{}'::integer[]))[1:50])
      AND c.status <> 'closed'
    ORDER BY c.caseid
  LOOP
    RETURN QUERY
    WITH sug AS (
      SELECT s.incidentid, s.score, s.reasons, s.n
      FROM public.suggest_incidents_for_case(v_caseid, 20)
             WITH ORDINALITY AS s(incidentid, score, reasons, matchedincidentid, n)
    ),
    top AS (SELECT * FROM sug ORDER BY sug.n LIMIT 1),
    case_plates AS (
      SELECT DISTINCT public.normalize_plate(v.licenceplatenumber) AS plate
      FROM public.crimescene cs
      JOIN public.media m         ON m.incidentid = cs.incidentid
      JOIN public.detection d     ON d.mediaid = m.mediaid
      JOIN public.vehicledetail v ON v.detectionid = d.detectionid
      WHERE cs.caseid = v_caseid
        AND public.normalize_plate(v.licenceplatenumber) IS NOT NULL
    ),
    top_plates AS (
      SELECT p.plate, p.conf,
             CASE WHEN EXISTS (SELECT 1 FROM case_plates cp WHERE cp.plate = p.plate)
                    THEN 'same'
                  WHEN EXISTS (SELECT 1 FROM case_plates cp
                                WHERE public.plates_similar(cp.plate, p.plate))
                    THEN 'similar'
             END AS platematch
      FROM (SELECT public.normalize_plate(v.licenceplatenumber) AS plate,
                   max(COALESCE(v.plateconfidence, 0)) AS conf
              FROM top t
              JOIN public.media m         ON m.incidentid = t.incidentid
              JOIN public.detection d     ON d.mediaid = m.mediaid
              JOIN public.vehicledetail v ON v.detectionid = d.detectionid
             WHERE public.normalize_plate(v.licenceplatenumber) IS NOT NULL
             GROUP BY 1) p
    ),
    best_plate AS (
      SELECT tp.plate, tp.platematch FROM top_plates tp
      ORDER BY CASE tp.platematch WHEN 'same' THEN 0 WHEN 'similar' THEN 1 ELSE 2 END,
               tp.conf DESC, tp.plate
      LIMIT 1
    )
    SELECT v_caseid, t.incidentid, t.score, t.reasons,
           ((SELECT count(*) FROM sug) - 1)::integer,
           bp.plate, bp.platematch
    FROM top t
    LEFT JOIN best_plate bp ON true;
  END LOOP;
END;
$$;


-- --- 8. privileges
-- internal helpers and trigger functions, not callable from the app
REVOKE EXECUTE ON FUNCTION public.protect_detection_suspect()        FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.check_suspect()                    FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.log_suspect_review_event()         FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.log_suspect_edit_event()           FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.person_detection_context(integer)  FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.review_possible_suspect(integer, text, text, text, text) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.update_suspect_details(integer, text, text)             FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.undo_suspect_review(integer, text)                      FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.case_card_suggestions(integer[])                        FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.list_submissions(text, integer, text, integer, text, timestamptz, integer, text, integer[]) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.list_cases(text, text, integer, integer, timestamptz, integer) FROM PUBLIC, anon;

-- The pipeline (service_role) never reviews suspects. Supabase grants it new
-- functions by default, so we have to revoke that explicitly.
REVOKE EXECUTE ON FUNCTION public.review_possible_suspect(integer, text, text, text, text) FROM service_role;
REVOKE EXECUTE ON FUNCTION public.update_suspect_details(integer, text, text)             FROM service_role;
REVOKE EXECUTE ON FUNCTION public.undo_suspect_review(integer, text)                      FROM service_role;
GRANT EXECUTE ON FUNCTION public.review_possible_suspect(integer, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_suspect_details(integer, text, text)             TO authenticated;
GRANT EXECUTE ON FUNCTION public.undo_suspect_review(integer, text)                      TO authenticated;
GRANT EXECUTE ON FUNCTION public.case_card_suggestions(integer[])                        TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_submissions(text, integer, text, integer, text, timestamptz, integer, text, integer[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_cases(text, text, integer, integer, timestamptz, integer) TO authenticated, service_role;
