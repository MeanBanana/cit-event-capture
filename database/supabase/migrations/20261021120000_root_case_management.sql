-- Root admin can see every case and delete closed ones, from the web console.
--
-- root_list_cases() lists every case with its status for the console's Cases
-- page (which does the grouping/filtering). Root only.
--
-- delete_closed_case(caseid) deletes a closed case, root only. Works like any
-- other case delete (20261005163000): the submissions survive and go back to
-- the review queue, assignments/chat/AI data cascade, and the history stays
-- with a 'case_deleted' line added.
--
-- The cases_delete policy used to be "any admin". Now it's root + closed
-- only, so the same rule holds even for direct table deletes.

-- --- 1. root_list_cases
CREATE OR REPLACE FUNCTION public.root_list_cases()
  RETURNS TABLE (
    caseid        integer,
    title         text,
    description   text,
    status        text,
    datecreated   timestamptz,
    dateclosed    timestamptz,
    createdbyname text,
    incidentcount integer,
    investigators integer,
    lastactivity  timestamptz)
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_root_admin() THEN
    RAISE EXCEPTION 'Only the root administrator can see all cases'
      USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT c.caseid, c.title::text, c.description, c.status::text, c.datecreated, c.dateclosed,
         NULLIF(btrim(concat_ws(' ', u.firstname, u.surname)), ''),
         (SELECT count(*)::integer FROM public.crimescene cs WHERE cs.caseid = c.caseid),
         (SELECT count(*)::integer FROM public.caseassignment ca
           WHERE ca.caseid = c.caseid AND ca.assignmentstatus = 'active'),
         GREATEST(c.datecreated,
                  (SELECT max(e.occurredat) FROM public.caseevent e WHERE e.caseid = c.caseid))
  FROM public.cases c
  LEFT JOIN public."User" u ON u.userid = c.createdby
  ORDER BY c.caseid DESC;
END;
$$;


-- --- 2. delete_closed_case
CREATE OR REPLACE FUNCTION public.delete_closed_case(p_caseid integer)
  RETURNS jsonb
  LANGUAGE plpgsql
  VOLATILE SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_case public.cases;
  v_incidents integer;
BEGIN
  IF NOT public.is_root_admin() THEN
    RAISE EXCEPTION 'Only the root administrator can delete cases.'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_case FROM public.cases WHERE caseid = p_caseid FOR UPDATE;
  IF v_case.caseid IS NULL THEN
    RAISE EXCEPTION 'That case no longer exists.' USING ERRCODE = 'P0002';
  END IF;
  IF v_case.status <> 'closed' THEN
    RAISE EXCEPTION 'Only closed cases can be deleted. Close the case first.'
      USING ERRCODE = '42501';
  END IF;

  SELECT count(*)::integer INTO v_incidents
    FROM public.crimescene WHERE caseid = p_caseid;

  DELETE FROM public.cases WHERE caseid = p_caseid;   -- the triggers handle the rest
  RETURN jsonb_build_object('caseid', p_caseid, 'title', v_case.title,
                            'incidents', v_incidents);
END;
$$;


-- --- 3. direct deletes: root only, closed cases only
DROP POLICY "cases_delete" ON public.cases;

CREATE POLICY "cases_delete" ON public.cases
  FOR DELETE TO authenticated
  USING ((SELECT public.is_root_admin()) AND status = 'closed');


-- --- privileges (each function checks the caller itself)
REVOKE EXECUTE ON FUNCTION public.root_list_cases()            FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.delete_closed_case(integer)  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.root_list_cases()            TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.delete_closed_case(integer)  TO authenticated, service_role;
