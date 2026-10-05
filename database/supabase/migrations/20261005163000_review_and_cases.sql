-- =====================================================================
-- Argus Shield: reviewing submissions + managing cases (admin)
--
-- Workflow
--   1. A citizen reports an incident -> crimescene row, reviewstatus 'pending'.
--   2. An admin reviews it:
--        accept     -> added to a new or existing case  ('accepted')
--        reject     -> kept on record, not used         ('rejected')
--        duplicate  -> linked to the original incident  ('duplicate';
--                      it follows the original into its case)
--      and can undo any of these (reopen -> 'pending').
--   3. In a case the admin assigns / removes investigators and changes
--      the status (open / under_review / closed).
--
-- Every admin action is a database function: it checks the caller is an
-- admin and does all of its changes in one transaction, so nothing is ever
-- left half done. They are SECURITY INVOKER, so the normal RLS rules and
-- triggers still apply on top.
--
-- Contents
--   1. crimescene review columns + consistency rules
--   2. who may change them (trigger)
--   3. deleting a case sends its incidents back to 'pending'
--   4. admin action functions
--   5. list functions for the app
--   6. admin_overview_stats / recent_activity updated
--   7. privileges
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Review columns
-- ---------------------------------------------------------------------
ALTER TABLE public.crimescene
  ADD COLUMN reviewstatus varchar(20) NOT NULL DEFAULT 'pending'
    CHECK (reviewstatus IN ('pending', 'accepted', 'rejected', 'duplicate')),
  ADD COLUMN reviewedby   integer REFERENCES public."User" (userid),
  ADD COLUMN reviewedat   timestamptz,
  ADD COLUMN reviewnote   text,          -- e.g. the reason for a rejection
  ADD COLUMN duplicateof  integer REFERENCES public.crimescene (incidentid);

-- Incidents already in a case count as accepted
UPDATE public.crimescene SET reviewstatus = 'accepted' WHERE caseid IS NOT NULL;

-- The review status must match the case / duplicate links:
--   pending, rejected  -> not in a case, not a duplicate
--   accepted           -> in a case, not a duplicate
--   duplicate          -> points at another incident (in its case, if any)
ALTER TABLE public.crimescene ADD CONSTRAINT crimescene_review_check CHECK (
     (reviewstatus IN ('pending', 'rejected') AND caseid IS NULL AND duplicateof IS NULL)
  OR (reviewstatus = 'accepted'  AND caseid IS NOT NULL AND duplicateof IS NULL)
  OR (reviewstatus = 'duplicate' AND duplicateof IS NOT NULL AND duplicateof <> incidentid)
);

CREATE INDEX idx_crimescene_reviewstatus ON public.crimescene (reviewstatus);
CREATE INDEX idx_crimescene_duplicateof  ON public.crimescene (duplicateof);
CREATE INDEX idx_crimescene_reviewedby   ON public.crimescene (reviewedby);


-- ---------------------------------------------------------------------
-- 2. Only admins may review or move incidents between cases
--    (replaces the caseid-only version from the cases migration)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_crimescene_caseid()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon')
     AND public.current_user_role() IS DISTINCT FROM 'admin'
  THEN
    IF TG_OP = 'INSERT' THEN
      IF NEW.caseid IS NOT NULL OR NEW.reviewstatus <> 'pending'
         OR NEW.reviewedby IS NOT NULL OR NEW.reviewedat IS NOT NULL
         OR NEW.reviewnote IS NOT NULL OR NEW.duplicateof IS NOT NULL
      THEN
        RAISE EXCEPTION 'Only admins can review submissions or add them to cases';
      END IF;
    ELSIF NEW.caseid       IS DISTINCT FROM OLD.caseid
       OR NEW.reviewstatus IS DISTINCT FROM OLD.reviewstatus
       OR NEW.reviewedby   IS DISTINCT FROM OLD.reviewedby
       OR NEW.reviewedat   IS DISTINCT FROM OLD.reviewedat
       OR NEW.reviewnote   IS DISTINCT FROM OLD.reviewnote
       OR NEW.duplicateof  IS DISTINCT FROM OLD.duplicateof
    THEN
      RAISE EXCEPTION 'Only admins can review submissions or add them to cases';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


-- ---------------------------------------------------------------------
-- 3. Deleting a case: its incidents go back to the review queue instead
--    of breaking the rules above (runs before crimescene.caseid is
--    cleared by the foreign key)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.release_case_incidents()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  UPDATE public.crimescene
     SET caseid = NULL, reviewstatus = 'pending',
         reviewedby = NULL, reviewedat = NULL, reviewnote = NULL
   WHERE caseid = OLD.caseid AND reviewstatus = 'accepted';
  UPDATE public.crimescene
     SET caseid = NULL
   WHERE caseid = OLD.caseid;   -- duplicates stay duplicates
  RETURN OLD;
END;
$$;

CREATE TRIGGER release_case_incidents
  BEFORE DELETE ON public.cases
  FOR EACH ROW EXECUTE FUNCTION public.release_case_incidents();


-- ---------------------------------------------------------------------
-- 4. Admin actions
-- ---------------------------------------------------------------------

-- Stops the calling function unless the signed-in user is an admin
CREATE OR REPLACE FUNCTION public.require_admin()
  RETURNS void
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF public.current_user_role() IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Only admins can do this' USING ERRCODE = '42501';
  END IF;
END;
$$;

-- Puts one incident into a case (accepting it), and its duplicates with it.
-- Used by create_case and add_incidents_to_case.
CREATE OR REPLACE FUNCTION public.attach_incident(p_incidentid integer, p_caseid integer)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  PERFORM public.require_admin();

  UPDATE public.crimescene
     SET caseid = p_caseid, reviewstatus = 'accepted', duplicateof = NULL,
         reviewedby = public.current_user_id(), reviewedat = now(), reviewnote = NULL
   WHERE incidentid = p_incidentid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Incident % not found', p_incidentid;
  END IF;

  UPDATE public.crimescene SET caseid = p_caseid WHERE duplicateof = p_incidentid;
END;
$$;

-- New case; optionally with incidents in it straight away. Returns caseid.
CREATE OR REPLACE FUNCTION public.create_case(
  p_title       text,
  p_description text      DEFAULT NULL,
  p_incidentids integer[] DEFAULT '{}'
)
  RETURNS integer
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
DECLARE
  v_caseid integer;
  v_id     integer;
BEGIN
  PERFORM public.require_admin();
  IF NULLIF(trim(COALESCE(p_title, '')), '') IS NULL THEN
    RAISE EXCEPTION 'A case needs a title';
  END IF;

  INSERT INTO public.cases (title, description, createdby)
  VALUES (left(trim(p_title), 150), NULLIF(trim(COALESCE(p_description, '')), ''),
          public.current_user_id())
  RETURNING caseid INTO v_caseid;

  FOREACH v_id IN ARRAY COALESCE(p_incidentids, '{}') LOOP
    PERFORM public.attach_incident(v_id, v_caseid);
  END LOOP;

  RETURN v_caseid;
END;
$$;

-- Adds (or moves) incidents into an existing, not-closed case
CREATE OR REPLACE FUNCTION public.add_incidents_to_case(
  p_caseid      integer,
  p_incidentids integer[]
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
DECLARE
  v_status text;
  v_id     integer;
BEGIN
  PERFORM public.require_admin();
  SELECT status INTO v_status FROM public.cases WHERE caseid = p_caseid;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Case % not found', p_caseid;
  ELSIF v_status = 'closed' THEN
    RAISE EXCEPTION 'Case % is closed; reopen it before adding incidents', p_caseid;
  END IF;

  FOREACH v_id IN ARRAY COALESCE(p_incidentids, '{}') LOOP
    PERFORM public.attach_incident(v_id, p_caseid);
  END LOOP;
END;
$$;

-- Back to 'pending': undoes accept / reject / duplicate. Also used for
-- "Remove from case". Its duplicates leave the case with it.
CREATE OR REPLACE FUNCTION public.reopen_submission(p_incidentid integer)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  PERFORM public.require_admin();

  UPDATE public.crimescene
     SET caseid = NULL, reviewstatus = 'pending', duplicateof = NULL,
         reviewedby = NULL, reviewedat = NULL, reviewnote = NULL
   WHERE incidentid = p_incidentid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Incident % not found', p_incidentid;
  END IF;

  UPDATE public.crimescene SET caseid = NULL WHERE duplicateof = p_incidentid;
END;
$$;

-- Rejected: stays on record (evidence is never deleted), not in any case
CREATE OR REPLACE FUNCTION public.reject_submission(
  p_incidentid integer,
  p_note       text DEFAULT NULL
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  PERFORM public.require_admin();

  UPDATE public.crimescene
     SET caseid = NULL, reviewstatus = 'rejected', duplicateof = NULL,
         reviewedby = public.current_user_id(), reviewedat = now(),
         reviewnote = NULLIF(trim(COALESCE(p_note, '')), '')
   WHERE incidentid = p_incidentid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Incident % not found', p_incidentid;
  END IF;

  UPDATE public.crimescene SET caseid = NULL WHERE duplicateof = p_incidentid;
END;
$$;

-- Duplicate of another incident: joins the original's case (if it has one).
-- Always points at the ORIGINAL, never at another duplicate.
CREATE OR REPLACE FUNCTION public.mark_duplicate(
  p_incidentid integer,
  p_originalid integer
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
DECLARE
  v_original integer := p_originalid;
  v_dupof    integer;
  v_caseid   integer;
  v_status   text;
BEGIN
  PERFORM public.require_admin();

  SELECT duplicateof, caseid, reviewstatus INTO v_dupof, v_caseid, v_status
  FROM public.crimescene WHERE incidentid = v_original;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Incident % not found', p_originalid;
  END IF;
  IF v_status = 'duplicate' THEN          -- follow to the real original
    v_original := v_dupof;
    SELECT caseid INTO v_caseid FROM public.crimescene WHERE incidentid = v_original;
  END IF;
  IF v_original = p_incidentid THEN
    RAISE EXCEPTION 'An incident cannot be a duplicate of itself';
  END IF;

  UPDATE public.crimescene
     SET reviewstatus = 'duplicate', duplicateof = v_original, caseid = v_caseid,
         reviewedby = public.current_user_id(), reviewedat = now(), reviewnote = NULL
   WHERE incidentid = p_incidentid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Incident % not found', p_incidentid;
  END IF;

  -- anything that was a duplicate of this one now points at the original
  UPDATE public.crimescene
     SET duplicateof = v_original, caseid = v_caseid
   WHERE duplicateof = p_incidentid;
END;
$$;

-- Assigns an investigator to a case (does nothing if already assigned).
-- Returns the assignment id.
CREATE OR REPLACE FUNCTION public.assign_investigator(
  p_caseid integer,
  p_userid integer
)
  RETURNS integer
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
DECLARE
  v_status text;
  v_id     integer;
BEGIN
  PERFORM public.require_admin();

  SELECT status INTO v_status FROM public.cases WHERE caseid = p_caseid;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Case % not found', p_caseid;
  ELSIF v_status = 'closed' THEN
    RAISE EXCEPTION 'Case % is closed; reopen it before assigning investigators', p_caseid;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.investigator WHERE userid = p_userid) THEN
    RAISE EXCEPTION 'User % is not an investigator', p_userid;
  END IF;

  SELECT assignmentid INTO v_id FROM public.caseassignment
   WHERE caseid = p_caseid AND assignedto = p_userid AND assignmentstatus = 'active';
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO public.caseassignment (caseid, assignedto, assignedby)
  VALUES (p_caseid, p_userid, public.current_user_id())
  RETURNING assignmentid INTO v_id;
  RETURN v_id;
END;
$$;

-- Ends an assignment; the row stays as history
CREATE OR REPLACE FUNCTION public.unassign_investigator(p_assignmentid integer)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  PERFORM public.require_admin();
  UPDATE public.caseassignment
     SET assignmentstatus = 'closed', dateunassigned = now()
   WHERE assignmentid = p_assignmentid AND assignmentstatus = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assignment % not found or already ended', p_assignmentid;
  END IF;
END;
$$;


-- ---------------------------------------------------------------------
-- 5. Lists for the app
-- ---------------------------------------------------------------------

-- Submissions, newest reported first. Now with review details and filters:
--   p_review  null = all, or 'pending' / 'accepted' / 'rejected' / 'duplicate'
--   p_caseid  only the incidents in that case
-- (signature changed, so the old version is dropped first)
DROP FUNCTION public.list_submissions(text, integer);

CREATE FUNCTION public.list_submissions(
  p_search text    DEFAULT NULL,
  p_limit  integer DEFAULT 20,
  p_review text    DEFAULT NULL,
  p_caseid integer DEFAULT NULL
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
    caseid       integer,
    casetitle    varchar,
    reviewstatus varchar,
    reviewedat   timestamptz,
    reviewnote   text,
    duplicateof  integer
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  WITH q AS (
    SELECT NULLIF(trim(COALESCE(p_search, '')), '') AS raw
  ), t AS (
    SELECT raw,
           replace(replace(replace(raw, '\', '\\'), '%', '\%'), '_', '\_') AS term,
           CASE WHEN raw ~* '^(inc)?[\s#-]*[0-9]{1,9}$'
                THEN substring(raw FROM '[0-9]+')::integer END AS num
    FROM q
  )
  SELECT cs.incidentid, cs.location, cs.datetime, cs.attacktype, cs.status,
         cs.description, cs.reportedby,
         NULLIF(trim(u.firstname || ' ' || u.surname), '') AS reportername,
         (SELECT count(*)::integer FROM public.media m
           WHERE m.incidentid = cs.incidentid) AS mediacount,
         cs.datereported, cs.caseid, c.title AS casetitle,
         cs.reviewstatus, cs.reviewedat, cs.reviewnote, cs.duplicateof
  FROM public.crimescene cs
  LEFT JOIN public."User" u ON u.userid = cs.reportedby
  LEFT JOIN public.cases  c ON c.caseid = cs.caseid
  CROSS JOIN t
  WHERE (t.raw IS NULL
         OR cs.incidentid = t.num
         OR cs.location ILIKE '%' || t.term || '%')
    AND (NULLIF(p_review, '') IS NULL OR cs.reviewstatus = p_review)
    AND (p_caseid IS NULL OR cs.caseid = p_caseid)
  ORDER BY cs.datereported DESC, cs.incidentid DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
$$;

-- Cases, most recently active first (created, or an incident added).
--   p_search  'CASE-0003', 'case 3', '#3', '3' -> case 3; text -> title
--   p_status  null = all, 'active' = open + under_review, or one status
--   p_caseid  just that case (for the case details page)
CREATE OR REPLACE FUNCTION public.list_cases(
  p_search text    DEFAULT NULL,
  p_status text    DEFAULT NULL,
  p_limit  integer DEFAULT 20,
  p_caseid integer DEFAULT NULL
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
    investigators jsonb,          -- [{userid, name, badgenumber}] active only
    lastactivity  timestamptz
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  WITH q AS (
    SELECT NULLIF(trim(COALESCE(p_search, '')), '') AS raw
  ), t AS (
    SELECT raw,
           replace(replace(replace(raw, '\', '\\'), '%', '\%'), '_', '\_') AS term,
           CASE WHEN raw ~* '^(case)?[\s#-]*[0-9]{1,9}$'
                THEN substring(raw FROM '[0-9]+')::integer END AS num
    FROM q
  ), base AS (
    SELECT c.*,
           (SELECT count(*)::integer FROM public.crimescene cs
             WHERE cs.caseid = c.caseid) AS incidentcount,
           GREATEST(c.datecreated,
                    (SELECT max(cs.reviewedat) FROM public.crimescene cs
                      WHERE cs.caseid = c.caseid)) AS lastactivity
    FROM public.cases c
  )
  SELECT b.caseid, b.title, b.description, b.status, b.datecreated, b.dateclosed,
         NULLIF(trim(u.firstname || ' ' || u.surname), '') AS createdbyname,
         b.incidentcount,
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'userid', iu.userid,
                    'name', concat_ws(' ', i.rank, iu.firstname, iu.surname),
                    'badgenumber', i.badgenumber)
                  ORDER BY ca.dateassigned)
           FROM public.caseassignment ca
           JOIN public."User" iu ON iu.userid = ca.assignedto
           LEFT JOIN public.investigator i ON i.userid = ca.assignedto
           WHERE ca.caseid = b.caseid AND ca.assignmentstatus = 'active'
         ), '[]'::jsonb) AS investigators,
         b.lastactivity
  FROM base b
  LEFT JOIN public."User" u ON u.userid = b.createdby
  CROSS JOIN t
  WHERE (t.raw IS NULL
         OR b.caseid = t.num
         OR b.title ILIKE '%' || t.term || '%')
    AND (NULLIF(p_status, '') IS NULL
         OR (p_status = 'active' AND b.status IN ('open', 'under_review'))
         OR b.status = p_status)
    AND (p_caseid IS NULL OR b.caseid = p_caseid)
  ORDER BY b.lastactivity DESC, b.caseid DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
$$;

-- Who is (and was) assigned to a case: active first, then history
CREATE OR REPLACE FUNCTION public.list_case_assignments(p_caseid integer)
  RETURNS TABLE (
    assignmentid     integer,
    userid           integer,
    name             text,
    badgenumber      varchar,
    station          varchar,
    dutystatus       varchar,
    assignmentstatus varchar,
    dateassigned     timestamptz,
    dateunassigned   timestamptz,
    assignedbyname   text
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  SELECT ca.assignmentid, ca.assignedto,
         concat_ws(' ', i.rank, u.firstname, u.surname),
         i.badgenumber, i.station, i.dutystatus,
         ca.assignmentstatus, ca.dateassigned, ca.dateunassigned,
         NULLIF(trim(b.firstname || ' ' || b.surname), '')
  FROM public.caseassignment ca
  JOIN public."User" u ON u.userid = ca.assignedto
  LEFT JOIN public.investigator i ON i.userid = ca.assignedto
  LEFT JOIN public."User" b ON b.userid = ca.assignedby
  WHERE ca.caseid = p_caseid
  ORDER BY (ca.assignmentstatus = 'active') DESC, ca.dateassigned DESC
$$;


-- ---------------------------------------------------------------------
-- 6. Overview: Pending = submissions waiting for review; activity feed
--    also shows accepted / rejected / duplicate decisions
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_overview_stats()
  RETURNS TABLE (
    totalcases    integer,
    activecases   integer,
    pendingcases  integer,
    investigators integer
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  SELECT
    (SELECT count(*) FROM public.cases)::integer,
    (SELECT count(*) FROM public.cases
      WHERE status IN ('open', 'under_review'))::integer,
    (SELECT count(*) FROM public.crimescene WHERE reviewstatus = 'pending')::integer,
    (SELECT count(*) FROM public.investigator)::integer
$$;

CREATE OR REPLACE FUNCTION public.recent_activity(p_limit integer DEFAULT 5)
  RETURNS TABLE (
    tag        text,
    message    text,
    occurredat timestamptz
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  WITH events AS (
    SELECT 'NEW' AS tag,
           'New citizen submission: INC-' || lpad(cs.incidentid::text, 4, '0')
             || ', ' || cs.location AS message,
           cs.datereported AS occurredat
    FROM public.crimescene cs

    UNION ALL   -- an admin's decision on a submission
    SELECT CASE cs.reviewstatus WHEN 'accepted' THEN 'ADD'
                                WHEN 'rejected' THEN 'REJ'
                                ELSE 'DUP' END,
           'INC-' || lpad(cs.incidentid::text, 4, '0') ||
           CASE cs.reviewstatus
             WHEN 'accepted' THEN ' added to CASE-' || lpad(cs.caseid::text, 4, '0')
             WHEN 'rejected' THEN ' rejected'
             ELSE ' marked as duplicate of INC-' || lpad(cs.duplicateof::text, 4, '0')
           END,
           cs.reviewedat
    FROM public.crimescene cs
    WHERE cs.reviewedat IS NOT NULL

    UNION ALL
    SELECT 'CASE',
           'Case CASE-' || lpad(c.caseid::text, 4, '0') || ' created: ' || c.title,
           c.datecreated
    FROM public.cases c

    UNION ALL
    SELECT 'ASGN',
           concat_ws(' ', i.rank, u.firstname, u.surname)
             || ' assigned to CASE-' || lpad(ca.caseid::text, 4, '0'),
           ca.dateassigned
    FROM public.caseassignment ca
    JOIN public."User" u ON u.userid = ca.assignedto
    LEFT JOIN public.investigator i ON i.userid = ca.assignedto

    UNION ALL
    SELECT 'CLSD',
           'CASE-' || lpad(c.caseid::text, 4, '0') || ' closed: ' || c.title,
           c.dateclosed
    FROM public.cases c
    WHERE c.dateclosed IS NOT NULL

    UNION ALL
    SELECT 'INV',
           'Investigator added: ' || concat_ws(' ', i.rank, u.firstname, u.surname)
             || ' (' || i.badgenumber || ')',
           u.datecreated
    FROM public.investigator i
    JOIN public."User" u ON u.userid = i.userid

    UNION ALL
    SELECT 'VER',
           'Suspect confirmed on INC-' || lpad(s.incidentid::text, 4, '0'),
           s.dateconfirmed
    FROM public.suspect s
    WHERE s.dateconfirmed IS NOT NULL

    UNION ALL
    SELECT 'COR',
           'Detection D-' || lpad(cl.detectionid::text, 3, '0') || ' corrected by '
             || COALESCE(u.firstname || ' ' || u.surname, 'a user'),
           cl.correctiontimestamp
    FROM public.correctionlog cl
    LEFT JOIN public."User" u ON u.userid = cl.correctedby
  )
  SELECT tag, message, occurredat
  FROM events
  ORDER BY occurredat DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 5), 1), 50)
$$;


-- ---------------------------------------------------------------------
-- 7. Privileges: logged-in users only (each action checks for admin);
--    attach_incident and require_admin are helpers, not for the app
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.require_admin()                        FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.attach_incident(integer, integer)      FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.create_case(text, text, integer[])     FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.add_incidents_to_case(integer, integer[]) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.reopen_submission(integer)             FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.reject_submission(integer, text)       FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.mark_duplicate(integer, integer)       FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.assign_investigator(integer, integer)  FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.unassign_investigator(integer)         FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.list_submissions(text, integer, text, integer) FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.list_cases(text, text, integer, integer)       FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.list_case_assignments(integer)         FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.release_case_incidents()               FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.require_admin()                         TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.attach_incident(integer, integer)       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_case(text, text, integer[])      TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.add_incidents_to_case(integer, integer[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reopen_submission(integer)              TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reject_submission(integer, text)        TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_duplicate(integer, integer)        TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.assign_investigator(integer, integer)   TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.unassign_investigator(integer)          TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_submissions(text, integer, text, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_cases(text, text, integer, integer)       TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_case_assignments(integer)          TO authenticated, service_role;
