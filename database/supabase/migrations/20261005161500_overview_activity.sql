-- =====================================================================
-- Argus Shield: admin Overview - Pending tile + live Recent activity
--
-- 1. admin_overview_stats(): "pendingcases" now counts SUBMISSIONS that
--    are not in a case yet (crimescene.caseid IS NULL), so new citizen
--    reports show up on the dashboard straight away. The other three
--    numbers are unchanged.
--
-- 2. recent_activity(): the newest events, built from dates the database
--    already stores (no separate log table to keep in sync):
--      NEW   a citizen reported an incident        crimescene.datereported
--      CASE  an admin created a case               cases.datecreated
--      ASGN  an investigator was assigned          caseassignment.dateassigned
--      CLSD  a case was closed                     cases.dateclosed
--      INV   an investigator account was added     "User".datecreated
--      VER   an admin confirmed a suspect          suspect.dateconfirmed
--      COR   someone corrected an AI detection     correctionlog.correctiontimestamp
--
-- Both are SECURITY INVOKER: normal RLS applies, so only admins see
-- everything.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Pending = submissions not in a case
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
    -- submissions waiting for an admin to put them in a case
    (SELECT count(*) FROM public.crimescene WHERE caseid IS NULL)::integer,
    (SELECT count(*) FROM public.investigator)::integer
$$;


-- ---------------------------------------------------------------------
-- 2. recent_activity
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.recent_activity(p_limit integer DEFAULT 5)
  RETURNS TABLE (
    tag        text,         -- NEW, CASE, ASGN, CLSD, INV, VER, COR
    message    text,         -- e.g. 'New citizen submission: INC-0042, N1 Midrand'
    occurredat timestamptz
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
  WITH events AS (
    -- a citizen reported an incident
    SELECT 'NEW' AS tag,
           'New citizen submission: INC-' || lpad(cs.incidentid::text, 4, '0')
             || ', ' || cs.location AS message,
           cs.datereported AS occurredat
    FROM public.crimescene cs

    UNION ALL
    -- an admin created a case
    SELECT 'CASE',
           'Case CASE-' || lpad(c.caseid::text, 4, '0') || ' created: ' || c.title,
           c.datecreated
    FROM public.cases c

    UNION ALL
    -- an investigator was assigned to a case
    SELECT 'ASGN',
           concat_ws(' ', i.rank, u.firstname, u.surname)
             || ' assigned to CASE-' || lpad(ca.caseid::text, 4, '0'),
           ca.dateassigned
    FROM public.caseassignment ca
    JOIN public."User" u ON u.userid = ca.assignedto
    LEFT JOIN public.investigator i ON i.userid = ca.assignedto

    UNION ALL
    -- a case was closed
    SELECT 'CLSD',
           'CASE-' || lpad(c.caseid::text, 4, '0') || ' closed: ' || c.title,
           c.dateclosed
    FROM public.cases c
    WHERE c.dateclosed IS NOT NULL

    UNION ALL
    -- an investigator account was added
    SELECT 'INV',
           'Investigator added: ' || concat_ws(' ', i.rank, u.firstname, u.surname)
             || ' (' || i.badgenumber || ')',
           u.datecreated
    FROM public.investigator i
    JOIN public."User" u ON u.userid = i.userid

    UNION ALL
    -- an admin confirmed a suspect
    SELECT 'VER',
           'Suspect confirmed on INC-' || lpad(s.incidentid::text, 4, '0'),
           s.dateconfirmed
    FROM public.suspect s
    WHERE s.dateconfirmed IS NOT NULL

    UNION ALL
    -- someone corrected an AI detection
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
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 5), 1), 50)   -- 1 to 50 rows
$$;

REVOKE EXECUTE ON FUNCTION public.recent_activity(integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.recent_activity(integer) TO authenticated, service_role;
