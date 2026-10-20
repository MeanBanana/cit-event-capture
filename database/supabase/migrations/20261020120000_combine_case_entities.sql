-- ============================================================================
-- "This is the same person as Person 1": combine two people / vehicles /
-- weapons of a case by hand
-- ============================================================================
--
-- The AI sometimes keeps one real person (or car, or gun) as two entries,
-- e.g. Person 1 and Person 3, because they look different on two cameras.
-- On the View crops screen an admin, or an investigator assigned to the
-- case, picks "Same as Person 1" and confirms:
--
--   combine_case_entities(caseid, 'p3', 'p1')
--
--   * every picture of Person 3 moves to Person 1, as an admin decision
--     ('confirmed'): the AI never splits them again
--   * Person 3's open questions ("Is this Person 3?") become questions
--     about Person 1; answers of "No, not Person 3" now mean "not Person 1"
--   * guns held by Person 3 are now held by Person 1
--   * Person 3 is removed (the other numbers stay as they are, so nobody's
--     "Person 2" changes under them), the worker re-votes Person 1's
--     details and rewrites the case summary ('summary' job)
--   * the case history says who combined what
--
-- Same rules as the rest of a case: not on a closed case, only the same
-- kind (a person can't be combined with a car).
-- ============================================================================

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
  p_from   text,      -- the entry being viewed, e.g. 'p3' (Person 3)
  p_into   text       -- the one it is the same as, e.g. 'p1' (Person 1)
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

  -- the same lock the worker's ai_save_case takes, so the two never mix
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

  -- 1. "No, not Person 3" now also means "not Person 1" (for pictures that
  --    aren't being moved into Person 1 right now)
  INSERT INTO public.entitymatchrejection (detectionid, entityid, rejectedby, rejectedat)
  SELECT r.detectionid, v_into.entityid, r.rejectedby, r.rejectedat
    FROM public.entitymatchrejection r
   WHERE r.entityid = v_from.entityid
     AND NOT EXISTS (SELECT 1 FROM public.detection d
                      WHERE d.detectionid = r.detectionid AND d.caseentityid = v_from.entityid)
  ON CONFLICT DO NOTHING;

  -- this person decided they ARE the same: drop old "not Person 1"
  -- answers about the pictures that move
  DELETE FROM public.entitymatchrejection r
   USING public.detection d
   WHERE r.entityid = v_into.entityid AND r.detectionid = d.detectionid
     AND d.caseentityid = v_from.entityid
     AND d.matchstatus IN ('first', 'auto', 'confirmed');

  -- 2. the pictures: settled ones become an admin decision, open
  --    questions now ask about Person 1 (unless already answered "No")
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

  -- 3. guns held by Person 3 are held by Person 1; a combined gun keeps
  --    its holder (or takes the other one's)
  UPDATE public.caseentity SET heldbyentityid = v_into.entityid
   WHERE heldbyentityid = v_from.entityid;
  UPDATE public.caseentity
     SET heldbyentityid = COALESCE(heldbyentityid, v_from.heldbyentityid),
         coverpath      = COALESCE(coverpath, v_from.coverpath),
         updatedat      = now()
   WHERE entityid = v_into.entityid;

  -- 4. Person 3 goes (its rejections go with it, ON DELETE CASCADE)
  DELETE FROM public.caseentity WHERE entityid = v_from.entityid;

  -- 5. the worker re-votes Person 1 and rewrites the summary
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
