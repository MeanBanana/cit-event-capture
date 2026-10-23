-- Manually combining two people/vehicles/weapons in a case ("this is the
-- same person as Person 1").
--
-- The AI sometimes splits one real person into two entries, say Person 1 and
-- Person 3, because they look different on two cameras. On the View crops
-- screen an admin or assigned investigator picks "Same as Person 1":
--
--   combine_case_entities(caseid, 'p3', 'p1')
--
-- What happens:
--   - all of Person 3's pictures move to Person 1 as 'confirmed', so the AI
--     never splits them up again
--   - Person 3's open questions become questions about Person 1, and any
--     "No, not Person 3" answers now count as "not Person 1"
--   - guns Person 3 was holding now belong to Person 1
--   - Person 3 gets deleted. The other numbers don't shift, so nobody's
--     "Person 2" suddenly becomes someone else. The worker re-votes Person 1
--     and rewrites the summary.
--   - the case history records who combined what
--
-- Not allowed on closed cases, and only within the same kind.

ALTER TABLE public.caseevent DROP CONSTRAINT caseevent_eventtype_check;
ALTER TABLE public.caseevent ADD CONSTRAINT caseevent_eventtype_check
  CHECK (eventtype IN (
    'submitted', 'added_to_case', 'removed_from_case', 'rejected', 'duplicate', 'reopened',
    'case_created', 'case_edited', 'status_changed', 'case_deleted',
    'assigned', 'unassigned', 'lead_changed',
    'detection_verified', 'detection_unverified',
    'suspect_confirmed', 'suspect_dismissed', 'suspect_review_undone', 'suspect_edited',
    'ai_match_confirmed', 'ai_match_rejected',
    'detection_corrected',
    'ai_entities_combined'));

CREATE OR REPLACE FUNCTION public.combine_case_entities(
  p_caseid integer,
  p_from   text,      -- the one you're looking at, e.g. 'p3'
  p_into   text       -- the one it's actually the same as, e.g. 'p1'
)
  RETURNS jsonb
  LANGUAGE plpgsql
  VOLATILE SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_status text;
  v_from   public.caseentity;
  v_into   public.caseentity;
  v_moved  integer;
  v_det    integer;
BEGIN
  IF public.current_user_role() IS DISTINCT FROM 'admin'
     AND NOT public.is_assigned_to_case(p_caseid) THEN
    RAISE EXCEPTION 'Only admins and investigators assigned to this case can combine its people, vehicles and weapons'
      USING ERRCODE = '42501';
  END IF;

  -- same lock ai_save_case takes, so we never interleave with the worker
  SELECT status INTO v_status FROM public.cases WHERE caseid = p_caseid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Case % not found', p_caseid USING ERRCODE = 'P0002';
  END IF;
  IF v_status = 'closed' THEN
    RAISE EXCEPTION 'Case % is closed; reopen it first', p_caseid;
  END IF;

  SELECT * INTO v_from FROM public.caseentity
   WHERE caseid = p_caseid AND public.ai_entity_key(kind, number) = p_from FOR UPDATE;
  SELECT * INTO v_into FROM public.caseentity
   WHERE caseid = p_caseid AND public.ai_entity_key(kind, number) = p_into FOR UPDATE;
  IF v_from.entityid IS NULL OR v_into.entityid IS NULL THEN
    RAISE EXCEPTION 'Not found in this case any more. Pull down to refresh.' USING ERRCODE = 'P0002';
  END IF;
  IF v_from.entityid = v_into.entityid THEN
    RAISE EXCEPTION 'Choose a different one to combine with.';
  END IF;
  IF v_from.kind <> v_into.kind THEN
    RAISE EXCEPTION 'Only the same kind can be combined (a % with a %).', v_from.kind, v_into.kind;
  END IF;

  -- a) "No, not Person 3" now also means "not Person 1", for pictures that
  --    aren't being moved into Person 1 right now
  INSERT INTO public.entitymatchrejection (detectionid, entityid, rejectedby, rejectedat)
  SELECT r.detectionid, v_into.entityid, r.rejectedby, r.rejectedat
    FROM public.entitymatchrejection r
   WHERE r.entityid = v_from.entityid
     AND NOT EXISTS (SELECT 1 FROM public.detection d
                      WHERE d.detectionid = r.detectionid AND d.caseentityid = v_from.entityid)
  ON CONFLICT DO NOTHING;

  -- someone just decided these ARE the same, so drop old "not Person 1"
  -- answers on the pictures that are moving
  DELETE FROM public.entitymatchrejection r
   USING public.detection d
   WHERE r.entityid = v_into.entityid AND r.detectionid = d.detectionid
     AND d.caseentityid = v_from.entityid
     AND d.matchstatus IN ('first', 'auto', 'confirmed');

  -- b) pictures: settled ones become an admin decision, open questions now
  --    ask about Person 1 (unless already answered No)
  UPDATE public.detection d
     SET caseentityid = v_into.entityid,
         matchstatus  = 'confirmed',
         matchreasons = ARRAY['combined with ' || public.ai_entity_label(v_from.kind, v_from.number)
                              || ' by hand']
   WHERE d.caseentityid = v_from.entityid
     AND d.matchstatus IN ('first', 'auto', 'confirmed');
  GET DIAGNOSTICS v_moved = ROW_COUNT;

  FOR v_det IN
    SELECT d.detectionid FROM public.detection d
     WHERE d.caseentityid = v_from.entityid AND d.matchstatus = 'suggested'
  LOOP
    IF EXISTS (SELECT 1 FROM public.entitymatchrejection r
                WHERE r.detectionid = v_det AND r.entityid = v_into.entityid) THEN
      UPDATE public.detection SET caseentityid = NULL WHERE detectionid = v_det;
      PERFORM public.queue_ai_job('rematch', NULL, p_caseid, v_det);
    ELSE
      UPDATE public.detection SET caseentityid = v_into.entityid WHERE detectionid = v_det;
    END IF;
  END LOOP;

  -- c) Person 3's guns go to Person 1. A combined gun keeps its holder, or
  --    takes the other one's if it didn't have one.
  UPDATE public.caseentity SET heldbyentityid = v_into.entityid
   WHERE heldbyentityid = v_from.entityid;
  UPDATE public.caseentity
     SET heldbyentityid = COALESCE(heldbyentityid, v_from.heldbyentityid),
         coverpath      = COALESCE(coverpath, v_from.coverpath),
         updatedat      = now()
   WHERE entityid = v_into.entityid;

  -- d) delete Person 3 (its rejections cascade)
  DELETE FROM public.caseentity WHERE entityid = v_from.entityid;

  -- e) worker re-votes Person 1 and rewrites the summary
  UPDATE public.cases SET aisummarystatus = 'outdated'
   WHERE caseid = p_caseid AND aisummarystatus <> 'none';
  PERFORM public.queue_ai_job('summary', NULL, p_caseid);

  PERFORM public.log_case_event('ai_entities_combined', p_caseid, NULL,
    public.ai_entity_label(v_from.kind, v_from.number) || ' is the same as '
      || public.ai_entity_label(v_into.kind, v_into.number));

  RETURN jsonb_build_object(
    'entity_id', public.ai_entity_key(v_into.kind, v_into.number),
    'label',     public.ai_entity_label(v_into.kind, v_into.number),
    'moved',     v_moved);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.combine_case_entities(integer, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.combine_case_entities(integer, text, text) TO authenticated, service_role;
