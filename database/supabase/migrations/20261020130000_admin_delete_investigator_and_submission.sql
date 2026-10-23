-- Admins can delete an investigator's account, or a rejected submission.
--
-- Both are only ever called from Edge Functions using the service key, after
-- the function has checked the caller is an admin:
--   remove_investigator_account(userid)     from manage-investigator (delete)
--   delete_rejected_submission(incidentid)  from delete-submission
-- Deleting logins and footage needs the service key, and that can't live in
-- the app.
--
-- Removing an investigator ends all their active assignments (with a line in
-- each case's history). If they never actually did anything (no chat,
-- corrections, assignments...) we just delete the rows and the function
-- deletes the login ('deleted'). If they did, that work has to stay on the
-- case record, so we anonymise instead: name becomes "Former investigator",
-- username deleted_<id>, placeholder email, phone and investigator row
-- removed. The function then bans the login permanently and moves it to the
-- placeholder email so the real email and username are free again
-- ('anonymised').
--
-- Deleting a submission only works on rejected ones (not pending, accepted or
-- duplicates) and not while something else is marked as a duplicate of it.
-- It takes out the submission, its media rows, everything the AI found
-- (detections, details, possible suspects, corrections, jobs) and its own
-- history lines. The Edge Function then deletes the files from the bucket.

-- --- 1. remove_investigator_account
CREATE OR REPLACE FUNCTION public.remove_investigator_account(p_userid integer)
  RETURNS jsonb
  LANGUAGE plpgsql
  VOLATILE SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_user    public."User";
  v_name    text;
  v_case    integer;
  v_history boolean;
BEGIN
  SELECT * INTO v_user FROM public."User" WHERE userid = p_userid FOR UPDATE;
  IF NOT FOUND OR v_user.role <> 'investigator'
     OR NOT EXISTS (SELECT 1 FROM public.investigator WHERE userid = p_userid) THEN
    RAISE EXCEPTION 'That investigator account no longer exists.' USING ERRCODE = 'P0002';
  END IF;
  v_name := trim(v_user.firstname || ' ' || v_user.surname);

  -- end their active assignments, with a history line on each case
  FOR v_case IN
    UPDATE public.caseassignment
       SET assignmentstatus = 'closed', dateunassigned = now(), islead = false
     WHERE assignedto = p_userid AND assignmentstatus = 'active'
    RETURNING caseid
  LOOP
    PERFORM public.log_case_event('unassigned', v_case, NULL,
                                  v_name || ' (account deleted)');
  END LOOP;

  v_history :=
       EXISTS (SELECT 1 FROM public.caseassignment     WHERE assignedto = p_userid OR assignedby = p_userid)
    OR EXISTS (SELECT 1 FROM public.casemessage        WHERE senderid = p_userid)
    OR EXISTS (SELECT 1 FROM public.caseevent          WHERE actor = p_userid)
    OR EXISTS (SELECT 1 FROM public.correctionlog      WHERE correctedby = p_userid)
    OR EXISTS (SELECT 1 FROM public.crossreferencelink WHERE linkedby = p_userid)
    OR EXISTS (SELECT 1 FROM public.detection          WHERE verifiedby = p_userid OR suspectreviewedby = p_userid)
    OR EXISTS (SELECT 1 FROM public.suspect            WHERE confirmedby = p_userid)
    OR EXISTS (SELECT 1 FROM public.entitymatchrejection WHERE rejectedby = p_userid)
    OR EXISTS (SELECT 1 FROM public.crimescene         WHERE reportedby = p_userid OR reviewedby = p_userid)
    OR EXISTS (SELECT 1 FROM public.media              WHERE uploadedby = p_userid)
    OR EXISTS (SELECT 1 FROM public.cases              WHERE createdby = p_userid);

  IF NOT v_history THEN
    DELETE FROM public."User" WHERE userid = p_userid;     -- investigator row goes with it
    RETURN jsonb_build_object('mode', 'deleted', 'authid', v_user.authid, 'name', v_name);
  END IF;

  DELETE FROM public.investigator WHERE userid = p_userid;
  UPDATE public."User"
     SET firstname   = 'Former',
         surname     = 'investigator',
         username    = 'deleted_' || p_userid,
         email       = 'deleted-' || p_userid || '@argus-shield.invalid',
         phonenumber = NULL
   WHERE userid = p_userid;
  RETURN jsonb_build_object('mode', 'anonymised', 'authid', v_user.authid, 'name', v_name,
                            'email', 'deleted-' || p_userid || '@argus-shield.invalid');
END;
$$;

-- --- 2. delete_rejected_submission
CREATE OR REPLACE FUNCTION public.delete_rejected_submission(p_incidentid integer)
  RETURNS jsonb
  LANGUAGE plpgsql
  VOLATILE SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_cs     public.crimescene;
  v_dups   integer;
  v_files  integer;
  v_dets   integer[];
BEGIN
  SELECT * INTO v_cs FROM public.crimescene WHERE incidentid = p_incidentid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'That submission no longer exists.' USING ERRCODE = 'P0002';
  END IF;
  IF v_cs.reviewstatus <> 'rejected' THEN
    RAISE EXCEPTION 'Only rejected submissions can be deleted. Reject it first.';
  END IF;
  SELECT count(*) INTO v_dups FROM public.crimescene WHERE duplicateof = p_incidentid;
  IF v_dups > 0 THEN
    RAISE EXCEPTION '% other submission(s) are marked as duplicates of this one. Reopen or delete those first.', v_dups;
  END IF;

  v_dets := ARRAY(SELECT d.detectionid FROM public.detection d
                    JOIN public.media m ON m.mediaid = d.mediaid
                   WHERE m.incidentid = p_incidentid);

  DELETE FROM public.correctionlog
   WHERE incidentid = p_incidentid
      OR detectionid = ANY (v_dets);
  DELETE FROM public.weapondetail  WHERE detectionid = ANY (v_dets);
  DELETE FROM public.vehicledetail WHERE detectionid = ANY (v_dets);
  DELETE FROM public.suspect
   WHERE incidentid = p_incidentid
      OR detectionid = ANY (v_dets);
  DELETE FROM public.detection     WHERE detectionid = ANY (v_dets);

  DELETE FROM public.media WHERE incidentid = p_incidentid;
  GET DIAGNOSTICS v_files = ROW_COUNT;

  -- its own history lines (submitted, rejected...). Lines that belong to a
  -- case's history stay put, their incidentid just goes NULL.
  DELETE FROM public.caseevent WHERE incidentid = p_incidentid AND caseid IS NULL;

  DELETE FROM public.crimescene WHERE incidentid = p_incidentid;   -- AI jobs go with it

  RETURN jsonb_build_object('incidentid', p_incidentid, 'files', v_files);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.remove_investigator_account(integer) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.delete_rejected_submission(integer)  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.remove_investigator_account(integer) TO service_role;
GRANT  EXECUTE ON FUNCTION public.delete_rejected_submission(integer)  TO service_role;
