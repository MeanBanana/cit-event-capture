-- =====================================================================
-- Argus Shield: list_investigators() for the admin Investigators screen
--
-- Returns investigators with their "User" details and number of active
-- case assignments, newest account first.
--
--   supabase.rpc('list_investigators')                          -> 20 newest
--   supabase.rpc('list_investigators', params: {'p_search': 'jhb'})
--       -> investigators whose badge number or name contains 'jhb'
--
-- SECURITY INVOKER: the normal RLS rules still apply, so only admins (and
-- investigators, who may see fellow investigators) get rows back. Citizens
-- get an empty list.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.list_investigators(
  p_search text    DEFAULT NULL,
  p_limit  integer DEFAULT 20
)
  RETURNS TABLE (
    userid      integer,
    firstname   varchar,
    surname     varchar,
    email       varchar,
    phonenumber varchar,
    rank        varchar,
    badgenumber varchar,
    station     varchar,
    unit        varchar,
    dutystatus  varchar,
    datecreated timestamptz,
    activecases integer
  )
  LANGUAGE sql STABLE SECURITY INVOKER
  SET search_path = ''
AS $$
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
$$;

REVOKE EXECUTE ON FUNCTION public.list_investigators(text, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.list_investigators(text, integer) TO authenticated, service_role;
