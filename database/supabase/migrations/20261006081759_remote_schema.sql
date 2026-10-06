SET local check_function_bodies = off;

ALTER TABLE "public"."caseassignment"
  DROP CONSTRAINT "caseassignment_assignmentstatus_check";

ALTER TABLE "public"."crimescene"
  DROP CONSTRAINT "crimescene_status_check";

ALTER TABLE "public"."crossreferencelink"
  DROP CONSTRAINT "crossreferencelink_entitytype_check";

ALTER TABLE "public"."crossreferencelink"
  DROP CONSTRAINT "crossreferencelink_verificationstatus_check";

ALTER TABLE "public"."detection"
  DROP CONSTRAINT "detection_detectiontype_check";

ALTER TABLE "public"."media"
  DROP CONSTRAINT "media_mediatype_check";

ALTER TABLE "public"."media"
  DROP CONSTRAINT "media_processingstatus_check";

ALTER TABLE "public"."User"
  ALTER COLUMN "authid" SET NOT NULL;

CREATE OR REPLACE FUNCTION public.accept_suggested_matches (
  p_incidentids integer[],
  p_caseids     integer[]
)
  RETURNS integer
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.add_incidents_to_case (
  p_caseid      integer,
  p_incidentids integer[]
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.admin_overview_stats()
  RETURNS TABLE (
    totalcases    integer,
    activecases   integer,
    pendingcases  integer,
    investigators integer
  )
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT
    (SELECT count(*) FROM public.cases)::integer,
    (SELECT count(*) FROM public.cases
      WHERE status IN ('open', 'under_review'))::integer,
    (SELECT count(*) FROM public.crimescene WHERE reviewstatus = 'pending')::integer,
    (SELECT count(*) FROM public.investigator)::integer
$function$;

CREATE OR REPLACE FUNCTION public.assign_investigator (
  p_caseid integer,
  p_userid integer
)
  RETURNS integer
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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

  INSERT INTO public.caseassignment (caseid, assignedto, assignedby, islead)
  VALUES (p_caseid, p_userid, public.current_user_id(),
          NOT EXISTS (SELECT 1 FROM public.caseassignment
                       WHERE caseid = p_caseid AND islead
                         AND assignmentstatus = 'active'))
  RETURNING assignmentid INTO v_id;
  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.attach_incident (
  p_incidentid integer,
  p_caseid     integer
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.create_case (
  p_title       text,
  p_description text      DEFAULT NULL::text,
  p_incidentids integer[] DEFAULT '{}'::integer[]
)
  RETURNS integer
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.distance_km (
  lat1 numeric,
  lon1 numeric,
  lat2 numeric,
  lon2 numeric
)
  RETURNS numeric
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  SELECT (2 * 6371 * asin(sqrt(
            power(sin(radians((lat2 - lat1)::double precision) / 2), 2)
          + cos(radians(lat1::double precision)) * cos(radians(lat2::double precision))
          * power(sin(radians((lon2 - lon1)::double precision) / 2), 2))))::numeric
$function$;

CREATE OR REPLACE FUNCTION public.incident_links()
  RETURNS TABLE (
    incident_a      integer,
    incident_b      integer,
    entitytype      character varying,
    matchconfidence numeric,
    verified        boolean
  )
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.incident_time (
  p_incidentid integer
)
  RETURNS timestamp WITH time zone
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT COALESCE(
    (SELECT min(m.capturetimestamp) FROM public.media m
      WHERE m.incidentid = p_incidentid),
    (SELECT cs.datetime FROM public.crimescene cs
      WHERE cs.incidentid = p_incidentid))
$function$;

CREATE OR REPLACE FUNCTION public.list_case_assignments (
  p_caseid integer
)
  RETURNS TABLE (
    assignmentid     integer,
    userid           integer,
    name             text,
    badgenumber      character varying,
    station          character varying,
    dutystatus       character varying,
    assignmentstatus character varying,
    dateassigned     timestamp with time zone,
    dateunassigned   timestamp with time zone,
    assignedbyname   text,
    islead           boolean
  )
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT ca.assignmentid, ca.assignedto,
         concat_ws(' ', i.rank, u.firstname, u.surname),
         i.badgenumber, i.station, i.dutystatus,
         ca.assignmentstatus, ca.dateassigned, ca.dateunassigned,
         NULLIF(trim(b.firstname || ' ' || b.surname), ''),
         ca.islead
  FROM public.caseassignment ca
  JOIN public."User" u ON u.userid = ca.assignedto
  LEFT JOIN public.investigator i ON i.userid = ca.assignedto
  LEFT JOIN public."User" b ON b.userid = ca.assignedby
  WHERE ca.caseid = p_caseid
  ORDER BY (ca.assignmentstatus = 'active') DESC,
           (ca.islead AND ca.assignmentstatus = 'active') DESC,
           ca.dateassigned DESC
$function$;

CREATE OR REPLACE FUNCTION public.list_case_events (
  p_caseid integer,
  p_limit  integer DEFAULT 30,
  p_before bigint  DEFAULT NULL::bigint
)
  RETURNS TABLE (
    eventid    bigint,
    eventtype  character varying,
    incidentid integer,
    detail     text,
    actorname  text,
    occurredat timestamp with time zone
  )
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT e.eventid, e.eventtype, e.incidentid, e.detail,
         NULLIF(trim(u.firstname || ' ' || u.surname), ''),
         e.occurredat
  FROM public.caseevent e
  LEFT JOIN public."User" u ON u.userid = e.actor
  WHERE e.caseid = p_caseid
    AND (p_before IS NULL OR e.eventid < p_before)
  ORDER BY e.eventid DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100)
$function$;

CREATE OR REPLACE FUNCTION public.list_incident_media (
  p_incidentid integer
)
  RETURNS TABLE (
    mediaid          integer,
    mediatype        character varying,
    storagepath      text,
    capturetimestamp timestamp with time zone,
    uploadtimestamp  timestamp with time zone,
    processingstatus character varying,
    aidescription    text,
    aidescribedat    timestamp with time zone,
    detections       integer,
    verified         integer
  )
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  SELECT m.mediaid, m.mediatype, m.storagepath, m.capturetimestamp,
         m.uploadtimestamp, m.processingstatus, m.aidescription, m.aidescribedat,
         (SELECT count(*)::integer FROM public.detection d WHERE d.mediaid = m.mediaid),
         (SELECT count(*)::integer FROM public.detection d
           WHERE d.mediaid = m.mediaid AND d.verified)
  FROM public.media m
  WHERE m.incidentid = p_incidentid
  ORDER BY COALESCE(m.capturetimestamp, m.uploadtimestamp), m.mediaid
$function$;

CREATE OR REPLACE FUNCTION public.list_investigators (
  p_search text    DEFAULT NULL::text,
  p_limit  integer DEFAULT 20
)
  RETURNS TABLE (
    userid      integer,
    firstname   character varying,
    surname     character varying,
    email       character varying,
    phonenumber character varying,
    rank        character varying,
    badgenumber character varying,
    station     character varying,
    unit        character varying,
    dutystatus  character varying,
    datecreated timestamp with time zone,
    activecases integer
  )
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  WITH q AS (
    -- the search text with LIKE wildcards (% and _) escaped, so typing
    -- them searches for the characters themselves
    SELECT NULLIF(
             replace(replace(replace(trim(COALESCE(p_search, '')),
               '\', '\\'), '%', '\%'), '_', '\_'),
             '') AS term
  )
  SELECT u.userid, u.firstname, u.surname, u.email, u.phonenumber,
         i.rank, i.badgenumber, i.station, i.unit, i.dutystatus,
         u.datecreated,
         (SELECT count(*)::integer
            FROM public.caseassignment ca
           WHERE ca.assignedto = u.userid
             AND ca.assignmentstatus = 'active') AS activecases
  FROM public.investigator i
  JOIN public."User" u ON u.userid = i.userid
  CROSS JOIN q
  WHERE q.term IS NULL
     OR i.badgenumber                    ILIKE '%' || q.term || '%'
     OR (u.firstname || ' ' || u.surname) ILIKE '%' || q.term || '%'
  ORDER BY u.datecreated DESC, u.userid DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)   -- 1 to 100 rows
$function$;

CREATE OR REPLACE FUNCTION public.list_linked_groups (
  p_limit  integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
  RETURNS TABLE (
    groupid         integer,
    incidentids     integer[],
    submissioncount integer,
    pendingcount    integer,
    linkcount       integer,
    verifiedlinks   integer,
    bestconfidence  numeric,
    plates          text[],
    latestreported  timestamp with time zone
  )
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  WITH RECURSIVE
  links AS (SELECT * FROM public.incident_links()),
  edges AS (
    SELECT incident_a AS a, incident_b AS b FROM links
    UNION
    SELECT incident_b, incident_a FROM links
  ),
  -- every incident reachable from each linked incident
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
$function$;

CREATE OR REPLACE FUNCTION public.list_location_groups (
  p_search text    DEFAULT NULL::text,
  p_review text    DEFAULT NULL::text,
  p_limit  integer DEFAULT 30,
  p_offset integer DEFAULT 0
)
  RETURNS TABLE (
    locationkey     text,
    label           text,
    submissioncount integer,
    pendingcount    integer,
    latestreported  timestamp with time zone
  )
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.list_suggested_matches (
  p_minscore integer DEFAULT 60,
  p_limit    integer DEFAULT 50
)
  RETURNS TABLE (
    incidentid        integer,
    caseid            integer,
    score             integer,
    reasons           text[],
    matchedincidentid integer,
    othercases        integer
  )
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
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
    -- best score per (submission, case)
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
$function$;

CREATE OR REPLACE FUNCTION public.log_assignment_event()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  v_name text;
BEGIN
  SELECT concat_ws(' ', i.rank, u.firstname, u.surname) INTO v_name
  FROM public."User" u
  LEFT JOIN public.investigator i ON i.userid = u.userid
  WHERE u.userid = NEW.assignedto;

  IF TG_OP = 'INSERT' THEN
    PERFORM public.log_case_event('assigned', NEW.caseid, NULL,
      v_name || CASE WHEN NEW.islead THEN ' (lead)' ELSE '' END);
    RETURN NEW;
  END IF;

  IF OLD.assignmentstatus = 'active' AND NEW.assignmentstatus <> 'active' THEN
    PERFORM public.log_case_event('unassigned', NEW.caseid, NULL, v_name);
  ELSIF NEW.islead AND NOT OLD.islead AND NEW.assignmentstatus = 'active' THEN
    PERFORM public.log_case_event('lead_changed', NEW.caseid, NULL, v_name || ' is now lead');
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.log_case_event (
  p_eventtype  text,
  p_caseid     integer,
  p_incidentid integer,
  p_detail     text    DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE sql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
  INSERT INTO public.caseevent (caseid, incidentid, actor, eventtype, detail)
  VALUES (p_caseid, p_incidentid, public.current_user_id(), p_eventtype, p_detail)
$function$;

CREATE OR REPLACE FUNCTION public.log_cases_event()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.log_case_event('case_created', NEW.caseid, NULL, NEW.title);
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    -- the case row is gone, so the reference goes in the detail
    PERFORM public.log_case_event('case_deleted', NULL, NULL,
      public.case_ref(OLD.caseid) || ': ' || OLD.title);
    RETURN OLD;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    PERFORM public.log_case_event('status_changed', NEW.caseid, NULL,
      public.status_label(OLD.status) || ' → ' || public.status_label(NEW.status));
  END IF;
  IF NEW.title IS DISTINCT FROM OLD.title
     OR NEW.description IS DISTINCT FROM OLD.description THEN
    PERFORM public.log_case_event('case_edited', NEW.caseid, NULL,
      CASE WHEN NEW.title IS DISTINCT FROM OLD.title
           THEN 'title: ' || NEW.title ELSE 'description changed' END);
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.log_crimescene_event()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  IF TG_OP = 'INSERT' THEN
    PERFORM public.log_case_event('submitted', NEW.caseid, NEW.incidentid, NEW.location);
    RETURN NEW;
  END IF;

  -- moved between cases: one event for the case it left, one for the
  -- case it joined, so both timelines are complete
  IF NEW.caseid IS DISTINCT FROM OLD.caseid THEN
    IF OLD.caseid IS NOT NULL THEN
      PERFORM public.log_case_event('removed_from_case', OLD.caseid, NEW.incidentid,
        CASE WHEN NEW.caseid IS NOT NULL THEN 'moved to ' || public.case_ref(NEW.caseid) END);
    END IF;
    IF NEW.caseid IS NOT NULL THEN
      PERFORM public.log_case_event('added_to_case', NEW.caseid, NEW.incidentid,
        CASE
          WHEN NEW.reviewstatus = 'duplicate'
            THEN 'as a duplicate of ' || public.incident_ref(NEW.duplicateof)
          WHEN OLD.caseid IS NOT NULL
            THEN 'moved from ' || public.case_ref(OLD.caseid)
        END);
    END IF;
  END IF;

  IF NEW.reviewstatus IS DISTINCT FROM OLD.reviewstatus
     OR NEW.duplicateof IS DISTINCT FROM OLD.duplicateof THEN
    CASE NEW.reviewstatus
      WHEN 'rejected' THEN
        PERFORM public.log_case_event('rejected', OLD.caseid, NEW.incidentid, NEW.reviewnote);
      WHEN 'duplicate' THEN
        PERFORM public.log_case_event('duplicate', NEW.caseid, NEW.incidentid,
          'of ' || public.incident_ref(NEW.duplicateof));
      WHEN 'pending' THEN
        PERFORM public.log_case_event('reopened', NULL, NEW.incidentid, NULL);
      ELSE
        NULL;   -- 'accepted' is logged as added_to_case above
    END CASE;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.log_detection_event()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  v_incidentid integer;
  v_caseid     integer;
BEGIN
  SELECT m.incidentid, cs.caseid INTO v_incidentid, v_caseid
  FROM public.media m
  JOIN public.crimescene cs ON cs.incidentid = m.incidentid
  WHERE m.mediaid = NEW.mediaid;

  PERFORM public.log_case_event(
    CASE WHEN NEW.verified THEN 'detection_verified' ELSE 'detection_unverified' END,
    v_caseid, v_incidentid,
    NEW.detectiontype || ' detection D-' || lpad(NEW.detectionid::text, 3, '0'));
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.mark_ai_summary_outdated()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  UPDATE public.crimescene
     SET aisummarystatus = 'outdated'
   WHERE incidentid = NEW.incidentid
     AND aisummarystatus = 'ready';
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.mark_duplicate (
  p_incidentid integer,
  p_originalid integer
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.match_incidents (
  p_candidates integer[],
  p_targets    integer[]
)
  RETURNS TABLE (
    candidateid integer,
    targetid    integer,
    score       integer,
    reasons     text[]
  )
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
  WITH
  inc AS (
    SELECT cs.incidentid, cs.latitude, cs.longitude, cs.locationkey,
           COALESCE(cap.t, cs.datetime) AS t,
           cap.t IS NOT NULL AS filmed       -- time came from the footage
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
$function$;

CREATE OR REPLACE FUNCTION public.normalize_plate (
  p_plate text
)
  RETURNS text
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  SELECT NULLIF(upper(regexp_replace(COALESCE(p_plate, ''), '[^A-Za-z0-9]', '', 'g')), '')
$function$;

CREATE OR REPLACE FUNCTION public.plates_similar (
  p_a text,
  p_b text
)
  RETURNS boolean
  LANGUAGE sql
  IMMUTABLE
  SET search_path TO ''
  AS $function$
  SELECT p_a IS NOT NULL AND p_b IS NOT NULL
     AND length(p_a) >= 5 AND length(p_b) >= 5
     AND abs(length(p_a) - length(p_b)) <= 1
     AND extensions.levenshtein(p_a, p_b) = 1
$function$;

CREATE OR REPLACE FUNCTION public.protect_crimescene_ai()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.protect_crimescene_caseid()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.protect_media_ai()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.recent_activity (
  p_limit integer DEFAULT 5
)
  RETURNS TABLE (
    tag        text,
    message    text,
    occurredat timestamp with time zone
  )
  LANGUAGE sql
  STABLE
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.reject_submission (
  p_incidentid integer,
  p_note       text    DEFAULT NULL::text
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.release_case_incidents()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.reopen_submission (
  p_incidentid integer
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.require_admin()
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
BEGIN
  IF public.current_user_role() IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Only admins can do this' USING ERRCODE = '42501';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_case_lead (
  p_assignmentid integer
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
DECLARE
  v_caseid integer;
BEGIN
  PERFORM public.require_admin();

  SELECT caseid INTO v_caseid FROM public.caseassignment
   WHERE assignmentid = p_assignmentid AND assignmentstatus = 'active';
  IF v_caseid IS NULL THEN
    RAISE EXCEPTION 'Assignment % not found or no longer active', p_assignmentid;
  END IF;

  UPDATE public.caseassignment SET islead = false
   WHERE caseid = v_caseid AND islead AND assignmentstatus = 'active'
     AND assignmentid <> p_assignmentid;
  UPDATE public.caseassignment SET islead = true
   WHERE assignmentid = p_assignmentid;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_case_status (
  p_caseid integer,
  p_status text
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
DECLARE
  v_role text := public.current_user_role();
  v_old  text;
BEGIN
  IF p_status IS NULL OR p_status NOT IN ('open', 'under_review', 'closed') THEN
    RAISE EXCEPTION 'Unknown case status: %', p_status;
  END IF;

  SELECT status INTO v_old FROM public.cases WHERE caseid = p_caseid FOR UPDATE;
  IF v_old IS NULL THEN
    RAISE EXCEPTION 'Case % not found', p_caseid;
  END IF;

  IF v_role = 'admin' THEN
    NULL;                                  -- admins may set any status
  ELSIF v_role = 'investigator' AND public.is_assigned_to_case(p_caseid) THEN
    IF v_old = 'closed' OR p_status = 'closed' THEN
      RAISE EXCEPTION 'Only an admin can close or reopen a case' USING ERRCODE = '42501';
    END IF;
  ELSE
    RAISE EXCEPTION 'You are not allowed to change this case' USING ERRCODE = '42501';
  END IF;

  IF v_old <> p_status THEN
    UPDATE public.cases SET status = p_status WHERE caseid = p_caseid;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_crimescene_datereported()
  RETURNS TRIGGER
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.suggest_cases_for_incident (
  p_incidentid integer,
  p_limit      integer DEFAULT 3
)
  RETURNS TABLE (
    caseid            integer,
    score             integer,
    reasons           text[],
    matchedincidentid integer
  )
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.suggest_incidents_for_case (
  p_caseid integer,
  p_limit  integer DEFAULT 5
)
  RETURNS TABLE (
    incidentid        integer,
    score             integer,
    reasons           text[],
    matchedincidentid integer
  )
  LANGUAGE plpgsql
  STABLE
  SET search_path TO ''
  AS $function$
DECLARE
  v_targets    integer[];
  v_candidates integer[];
BEGIN
  PERFORM public.require_admin();

  SELECT array_agg(cs.incidentid) INTO v_targets
  FROM public.crimescene cs WHERE cs.caseid = p_caseid;
  IF v_targets IS NULL THEN
    RETURN;                                -- empty case: nothing to compare
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
$function$;

CREATE OR REPLACE FUNCTION public.unassign_investigator (
  p_assignmentid integer
)
  RETURNS void
  LANGUAGE plpgsql
  SET search_path TO ''
  AS $function$
BEGIN
  PERFORM public.require_admin();
  UPDATE public.caseassignment
     SET assignmentstatus = 'closed', dateunassigned = now()
   WHERE assignmentid = p_assignmentid AND assignmentstatus = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Assignment % not found or already ended', p_assignmentid;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.verify_detection (
  p_detectionid integer,
  p_verified    boolean DEFAULT true
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO ''
  AS $function$
BEGIN
  IF public.current_user_role() NOT IN ('admin', 'investigator')
     OR NOT public.can_view_detection(p_detectionid) THEN
    RAISE EXCEPTION 'You are not allowed to verify this detection' USING ERRCODE = '42501';
  END IF;

  UPDATE public.detection
     SET verified   = p_verified,
         verifiedby = CASE WHEN p_verified THEN public.current_user_id() END,
         verifiedat = CASE WHEN p_verified THEN now() END
   WHERE detectionid = p_detectionid
     AND verified IS DISTINCT FROM p_verified;
END;
$function$;

ALTER TABLE "public"."User"
  ADD CONSTRAINT "User_username_key" UNIQUE (username);

ALTER TABLE "public"."caseassignment"
  ADD CONSTRAINT "caseassignment_assignmentstatus_check"
    CHECK (((assignmentstatus)::text = ANY ((ARRAY['active'::character varying, 'reassigned'::character varying, 'closed'::character varying])::text[])));

ALTER TABLE "public"."crimescene"
  ADD CONSTRAINT "crimescene_status_check"
    CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'closed'::character varying, 'under_review'::character varying])::text[])));

ALTER TABLE "public"."crossreferencelink"
  ADD CONSTRAINT "crossreferencelink_entitytype_check" CHECK (((entitytype)::text = ANY ((ARRAY['vehicle'::character varying, 'suspect'::character varying])::text[])));

ALTER TABLE "public"."crossreferencelink"
  ADD CONSTRAINT "crossreferencelink_verificationstatus_check"
    CHECK (((verificationstatus)::text = ANY ((ARRAY['pending'::character varying, 'verified'::character varying, 'rejected'::character varying])::text[])));

ALTER TABLE "public"."detection"
  ADD CONSTRAINT "detection_detectiontype_check"
    CHECK (((detectiontype)::text = ANY ((ARRAY['vehicle'::character varying, 'person'::character varying, 'weapon'::character varying])::text[])));

ALTER TABLE "public"."media"
  ADD CONSTRAINT "media_mediatype_check" CHECK (((mediatype)::text = ANY ((ARRAY['image'::character varying, 'video'::character varying, 'audio'::character varying])::text[])));

ALTER TABLE "public"."media"
  ADD CONSTRAINT "media_processingstatus_check"
    CHECK
    (((processingstatus)::text = ANY ((ARRAY['pending'::character varying, 'processing'::character varying, 'completed'::character varying, 'failed'::character varying])::text[])));

