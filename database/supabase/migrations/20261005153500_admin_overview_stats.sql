-- =====================================================================
-- Argus Shield: admin_overview_stats() for the admin Overview tab
--
-- One row with the four "System status" numbers:
--   totalcases     every case
--   activecases    cases that are 'open' or 'under_review'
--   pendingcases   active cases with no investigator actively assigned
--   investigators  every registered investigator
--
-- SECURITY INVOKER: normal RLS applies, so only an admin gets the real
-- totals (an investigator would only count their own cases).
-- =====================================================================

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
    (SELECT count(*) FROM public.cases c
      WHERE c.status IN ('open', 'under_review')
        AND NOT EXISTS (SELECT 1 FROM public.caseassignment ca
                         WHERE ca.caseid = c.caseid
                           AND ca.assignmentstatus = 'active'))::integer,
    (SELECT count(*) FROM public.investigator)::integer
$$;

REVOKE EXECUTE ON FUNCTION public.admin_overview_stats() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_overview_stats() TO authenticated, service_role;
