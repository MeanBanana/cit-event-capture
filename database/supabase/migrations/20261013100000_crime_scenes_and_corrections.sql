-- =====================================================================
-- Argus Shield: CRIME SCENES inside a case, and INVESTIGATOR CORRECTIONS
-- of what the AI found.
--
-- A case groups several crime scenes (crimescene rows). The case page now
-- shows one small card per crime scene (description, location, how many
-- suspects / vehicles / weapons) and a page per crime scene with its
-- footage, what the AI found and the corrections made to it.
--
-- After the AI has analysed a crime scene's footage, an investigator on
-- the case (or an admin) can correct what it found:
--
--   person    top colour, bottom colour
--   vehicle   type, make, model, colour, number plate
--   weapon    weapon type
--   any       "not a real person / vehicle / weapon" (dismissed)
--
-- Every correction goes through correct_detection() and is written to
-- correctionlog (who, when, which field, old -> new value, why). The app
-- can no longer change vehicledetail / weapondetail / correctionlog
-- directly, so nothing is changed without being logged.
--
-- While the footage is still waiting for the AI or being analysed, nothing
-- can be corrected: the app shows "Waiting for analysis" / "Analysing".
--
-- Corrections win over the AI:
--   * detection.corrections holds the corrected values; a re-run of the
--     analysis (ai_save_analysis) never touches it
--   * the worker reads the corrected values when it combines a case's
--     people / vehicles / weapons (ai_member), so the case summary follows
--   * a dismissed detection leaves its case entity and is never merged
--     into a case again (until the dismissal is undone)
--
-- Contents
--   1. correctionlog: + fieldname, note; writes only through the function
--   2. detection.corrections + who may write it
--   3. Helpers: AI value / current value of a field, analysis status
--   4. Worker: corrected values and dismissals
--   5. correct_detection()
--   6. list_case_crime_scenes(), get_crime_scene()
--   7. Privileges
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. correctionlog
--    fieldname is null only for rows written before this migration.
-- ---------------------------------------------------------------------
ALTER TABLE public.correctionlog
  ADD COLUMN fieldname varchar(30)
      CHECK (fieldname IN ('upper_clothing', 'lower_clothing',
                           'vehicle_type', 'make', 'model', 'colour', 'plate',
                           'weapon_type', 'dismissed')),
  ADD COLUMN note text CHECK (char_length(note) <= 500);

CREATE INDEX IF NOT EXISTS idx_correctionlog_detection_time
  ON public.correctionlog (detectionid, correctiontimestamp DESC);

-- Append-only, and only through correct_detection() (SECURITY DEFINER):
-- an app user inserting rows by hand could log a change that never
-- happened, or change a value without a log entry.
DROP POLICY IF EXISTS "correctionlog_insert" ON public.correctionlog;
REVOKE ALL ON public.correctionlog FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES
  ON public.correctionlog FROM authenticated;
REVOKE ALL ON SEQUENCE public.correctionlog_correctionid_seq FROM anon, authenticated;

-- vehicledetail / weapondetail: corrections only through correct_detection()
DROP POLICY IF EXISTS "vehicledetail_update" ON public.vehicledetail;
DROP POLICY IF EXISTS "weapondetail_update" ON public.weapondetail;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.vehicledetail FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.weapondetail FROM anon, authenticated;


-- ---------------------------------------------------------------------
-- 2. detection.corrections: {"plate": "ND654321", "dismissed": true, ...}
--    A key is there only while the value differs from the AI's. A JSON
--    null means "none / unknown" (e.g. no readable plate).
-- ---------------------------------------------------------------------
ALTER TABLE public.detection
  ADD COLUMN corrections jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD CONSTRAINT detection_corrections_check CHECK (jsonb_typeof(corrections) = 'object');

-- Same as before (20261012100100 8d), plus: corrections are written by
-- correct_detection() only - not by the app and not by the AI worker.
CREATE OR REPLACE FUNCTION public.protect_detection_ai()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon', 'service_role') AND (
       (TG_OP = 'INSERT' AND NEW.corrections <> '{}'::jsonb)
    OR (TG_OP = 'UPDATE' AND NEW.corrections IS DISTINCT FROM OLD.corrections))
  THEN
    RAISE EXCEPTION 'Corrections are made with correct_detection() only'
      USING ERRCODE = '42501';
  END IF;

  IF current_user IN ('authenticated', 'anon') AND (
       TG_OP = 'INSERT'
    OR NEW.trackid      IS DISTINCT FROM OLD.trackid
    OR NEW.firstseen    IS DISTINCT FROM OLD.firstseen
    OR NEW.lastseen     IS DISTINCT FROM OLD.lastseen
    OR NEW.framesseen   IS DISTINCT FROM OLD.framesseen
    OR NEW.attributes   IS DISTINCT FROM OLD.attributes
    OR NEW.crops        IS DISTINCT FROM OLD.crops
    -- (as text: pgvector's = lives in the extensions schema)
    OR NEW.appearance::text IS DISTINCT FROM OLD.appearance::text
    OR NEW.colourhist::text IS DISTINCT FROM OLD.colourhist::text
    OR NEW.caseentityid IS DISTINCT FROM OLD.caseentityid
    OR NEW.matchstatus  IS DISTINCT FROM OLD.matchstatus
    OR NEW.matchscore   IS DISTINCT FROM OLD.matchscore
    OR NEW.matchreasons IS DISTINCT FROM OLD.matchreasons)
  THEN
    RAISE EXCEPTION 'AI fields are written by the analysis pipeline only'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

-- A dismissed detection ("not a real weapon") never sits in a case entity,
-- even if a worker that loaded the case before the dismissal saves it
-- afterwards.
CREATE OR REPLACE FUNCTION public.detection_keep_dismissed_out()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF NEW.caseentityid IS NOT NULL
     AND COALESCE(NEW.corrections ->> 'dismissed', 'false') = 'true' THEN
    NEW.caseentityid := NULL;
    NEW.matchstatus  := NULL;
    NEW.matchscore   := NULL;
    NEW.matchreasons := NULL;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER detection_keep_dismissed_out
  BEFORE UPDATE OF caseentityid ON public.detection
  FOR EACH ROW EXECUTE FUNCTION public.detection_keep_dismissed_out();


-- ---------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------

-- The fields that can be corrected, per kind of detection (in screen order)
CREATE OR REPLACE FUNCTION public.correctable_fields(p_kind text)
  RETURNS text[]
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$
  SELECT CASE p_kind
    WHEN 'person'  THEN ARRAY['upper_clothing', 'lower_clothing', 'dismissed']
    WHEN 'vehicle' THEN ARRAY['vehicle_type', 'make', 'model', 'colour', 'plate', 'dismissed']
    WHEN 'weapon'  THEN ARRAY['weapon_type', 'dismissed']
    ELSE ARRAY[]::text[]
  END
$$;

-- What the AI said for a field (null = it didn't say)
CREATE OR REPLACE FUNCTION public.detection_ai_value(p_attributes jsonb, p_field text)
  RETURNS text
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$
  SELECT CASE p_field
    WHEN 'upper_clothing' THEN NULLIF(p_attributes ->> 'upper_clothing', '')
    WHEN 'lower_clothing' THEN NULLIF(p_attributes ->> 'lower_clothing', '')
    WHEN 'vehicle_type'   THEN NULLIF(p_attributes ->> 'class_name', '')
    WHEN 'make'           THEN NULLIF(p_attributes ->> 'make', '')
    WHEN 'model'          THEN NULLIF(p_attributes ->> 'model', '')
    WHEN 'colour'         THEN NULLIF(p_attributes ->> 'colour', '')
    WHEN 'plate'          THEN public.normalize_plate(p_attributes ->> 'plate')
    WHEN 'weapon_type'    THEN NULLIF(lower(p_attributes ->> 'class_name'), '')
    WHEN 'dismissed'      THEN 'false'
  END
$$;

-- The value that counts: the investigator's correction, else the AI's
CREATE OR REPLACE FUNCTION public.detection_value(
  p_attributes jsonb, p_corrections jsonb, p_field text)
  RETURNS text
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$
  SELECT CASE WHEN p_corrections ? p_field THEN p_corrections ->> p_field
              ELSE public.detection_ai_value(p_attributes, p_field) END
$$;

CREATE OR REPLACE FUNCTION public.detection_dismissed(p_corrections jsonb)
  RETURNS boolean
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$ SELECT COALESCE(p_corrections ->> 'dismissed', 'false') = 'true' $$;

-- Where a crime scene's footage is with the AI:
--   no_footage  nothing was uploaded
--   pending     waiting for the AI worker (queued, or not submitted yet)
--   analysing   the worker is analysing it right now
--   failed      no file could be analysed
--   done        analysed (failed > 0: some files could not be analysed)
CREATE OR REPLACE FUNCTION public.crime_scene_analysis(p_incidentid integer)
  RETURNS jsonb
  LANGUAGE sql STABLE
  SET search_path = ''
AS $$
  WITH f AS (
    SELECT count(*)                                                 AS files,
           count(*) FILTER (WHERE m.processingstatus = 'completed')  AS done,
           count(*) FILTER (WHERE m.processingstatus = 'failed')     AS failed,
           count(*) FILTER (WHERE m.processingstatus = 'processing') AS running,
           count(*) FILTER (WHERE m.processingstatus = 'pending')    AS waiting
    FROM public.media m
    WHERE m.incidentid = p_incidentid
  ),
  j AS (
    SELECT bool_or(a.status = 'processing') AS running,
           bool_or(a.status = 'queued')     AS queued
    FROM public.aijob a
    WHERE a.kind = 'analyse' AND a.incidentid = p_incidentid
      AND a.status IN ('queued', 'processing')
  )
  SELECT jsonb_build_object(
    'status', CASE
                WHEN f.files = 0 THEN 'no_footage'
                WHEN COALESCE(j.running, false) OR f.running > 0 THEN 'analysing'
                WHEN COALESCE(j.queued, false) OR f.waiting > 0 THEN 'pending'
                WHEN f.done = 0 THEN 'failed'
                ELSE 'done'
              END,
    'files',  f.files,
    'done',   f.done,
    'failed', f.failed)
  FROM f, j
$$;


-- ---------------------------------------------------------------------
-- 4. Worker: use the corrected values, skip dismissed detections
-- ---------------------------------------------------------------------

-- Same as 20261012100100 section 7, with the corrected values winning
CREATE OR REPLACE FUNCTION public.ai_member(p_detectionid integer)
  RETURNS jsonb
  LANGUAGE sql STABLE
  SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'key',          d.detectionid::text,
    'submission',   m.incidentid,
    'file_index',   m.mediaid,
    'file_name',    regexp_replace(m.storagepath, '^.*/', ''),
    'kind',         d.detectiontype,
    'track_id',     d.trackid,
    'first_seen',   COALESCE(d.firstseen, 0),
    'last_seen',    COALESCE(d.lastseen, d.firstseen, 0),
    'capture_time', m.capturetimestamp,
    'appearance',   CASE WHEN d.appearance IS NOT NULL OR d.colourhist IS NOT NULL THEN
                      jsonb_build_object('embedding',   to_jsonb(d.appearance::real[]),
                                         'colour_hist', to_jsonb(d.colourhist::real[])) END,
    'status',       d.matchstatus,
    'score',        d.matchscore,
    'reasons',      COALESCE(to_jsonb(d.matchreasons), '[]'::jsonb),
    'crops',        d.crops,
    'held_by',      wd.heldbydetectionid::text,
    'attributes',   CASE d.detectiontype
      WHEN 'person' THEN jsonb_build_object(
        'upper_clothing',            to_jsonb(public.detection_value(d.attributes, d.corrections, 'upper_clothing')),
        -- a corrected value is certain
        'upper_clothing_confidence', CASE WHEN d.corrections ? 'upper_clothing' THEN to_jsonb(1)
                                          ELSE d.attributes -> 'upper_clothing_confidence' END,
        'lower_clothing',            to_jsonb(public.detection_value(d.attributes, d.corrections, 'lower_clothing')),
        'lower_clothing_confidence', CASE WHEN d.corrections ? 'lower_clothing' THEN to_jsonb(1)
                                          ELSE d.attributes -> 'lower_clothing_confidence' END,
        'face_visible',              d.attributes -> 'face_visible',
        'face_size_px',              d.attributes -> 'face_size_px',
        'clothing_views',            d.attributes -> 'clothing_views')
      WHEN 'vehicle' THEN jsonb_build_object(
        'class_name',        COALESCE(to_jsonb(public.detection_value(d.attributes, d.corrections, 'vehicle_type')),
                                      to_jsonb(vd.vehicletype)),
        'make',              COALESCE(to_jsonb(public.detection_value(d.attributes, d.corrections, 'make')),
                                      to_jsonb(vd.make)),
        'make_confidence',   CASE WHEN d.corrections ? 'make' THEN to_jsonb(1)
                                  ELSE d.attributes -> 'make_confidence' END,
        'make_views',        d.attributes -> 'make_views',
        'colour',            COALESCE(to_jsonb(public.detection_value(d.attributes, d.corrections, 'colour')),
                                      to_jsonb(vd.colour)),
        'colour_confidence', CASE WHEN d.corrections ? 'colour' THEN to_jsonb(1)
                                  ELSE d.attributes -> 'colour_confidence' END,
        'plate',             CASE WHEN d.corrections ? 'plate'
                                  THEN to_jsonb(public.normalize_plate(d.corrections ->> 'plate'))
                                  ELSE to_jsonb(public.normalize_plate(
                                         COALESCE(vd.licenceplatenumber, d.attributes ->> 'plate'))) END,
        'plate_confidence',  CASE WHEN d.corrections ? 'plate' THEN to_jsonb(1)
                                  ELSE COALESCE(to_jsonb(vd.plateconfidence), d.attributes -> 'plate_confidence') END,
        'plate_reads',       d.attributes -> 'plate_reads',
        'frames_seen',       to_jsonb(d.framesseen))
      ELSE jsonb_build_object(
        'kind',              to_jsonb(public.detection_value(d.attributes, d.corrections, 'weapon_type')),
        'weapon_confidence', CASE WHEN d.corrections ? 'weapon_type' THEN to_jsonb(1)
                                  ELSE d.attributes -> 'weapon_confidence' END,
        'frames_seen',       to_jsonb(d.framesseen))
    END)
  FROM public.detection d
  JOIN public.media m ON m.mediaid = d.mediaid
  LEFT JOIN public.vehicledetail vd ON vd.detectionid = d.detectionid
  LEFT JOIN public.weapondetail  wd ON wd.detectionid = d.detectionid
  WHERE d.detectionid = p_detectionid
$$;

-- Same as before, without dismissed detections
CREATE OR REPLACE FUNCTION public.ai_load_submission(p_incidentid integer)
  RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_sub jsonb := public.ai_submission_info(p_incidentid);
BEGIN
  IF v_sub IS NULL THEN
    RAISE EXCEPTION 'Incident % not found', p_incidentid;
  END IF;
  RETURN v_sub || jsonb_build_object('members', COALESCE((
    -- fresh members: no case status yet (merge_submission decides)
    SELECT jsonb_agg(public.ai_member(d.detectionid)
                     || '{"status": null, "score": null, "reasons": []}'::jsonb
                     ORDER BY m.mediaid, d.detectiontype, d.trackid, d.detectionid)
    FROM public.media m
    JOIN public.detection d ON d.mediaid = m.mediaid
    WHERE m.incidentid = p_incidentid AND m.processingstatus <> 'failed'
      AND NOT public.detection_dismissed(d.corrections)), '[]'::jsonb));
END;
$$;


-- ---------------------------------------------------------------------
-- 5. correct_detection - an investigator corrects what the AI found
--
--   select correct_detection(812, 'plate', 'ND 654-321');
--   select correct_detection(812, 'dismissed', 'true', 'It is a parked car');
--   select correct_detection(812, 'plate', <the AI's value>);  -- undo
--
-- p_value: the new value as text ('' or null = none / unknown; for
-- 'dismissed' 'true' / 'false'). Setting the AI's own value again removes
-- the correction (the log keeps both steps).
-- Who: admins, and investigators assigned to the case while it is not
-- closed. Only once the AI has finished with the crime scene's footage.
-- Returns {correctionid, field, original, corrected}.
-- ---------------------------------------------------------------------
ALTER TABLE public.caseevent DROP CONSTRAINT caseevent_eventtype_check;
ALTER TABLE public.caseevent ADD CONSTRAINT caseevent_eventtype_check
  CHECK (eventtype IN (
    'submitted', 'added_to_case', 'removed_from_case', 'rejected', 'duplicate', 'reopened',
    'case_created', 'case_edited', 'status_changed', 'case_deleted',
    'assigned', 'unassigned', 'lead_changed',
    'detection_verified', 'detection_unverified',
    'suspect_confirmed', 'suspect_dismissed', 'suspect_review_undone', 'suspect_edited',
    'ai_match_confirmed', 'ai_match_rejected',
    'detection_corrected'));

-- "Person 2", "Vehicle 1" ... as the crime scene page numbers them
CREATE OR REPLACE FUNCTION public.detection_label(p_detectionid integer)
  RETURNS text
  LANGUAGE sql STABLE
  SET search_path = ''
AS $$
  SELECT initcap(x.detectiontype) || ' ' || x.n
  FROM (
    SELECT d.detectionid, d.detectiontype,
           row_number() OVER (PARTITION BY d.detectiontype
                              ORDER BY d.mediaid, d.firstseen NULLS FIRST, d.detectionid) AS n
    FROM public.detection d
    JOIN public.media m ON m.mediaid = d.mediaid
    WHERE m.incidentid = (SELECT m2.incidentid FROM public.detection d2
                            JOIN public.media m2 ON m2.mediaid = d2.mediaid
                           WHERE d2.detectionid = p_detectionid)
  ) x
  WHERE x.detectionid = p_detectionid
$$;

CREATE OR REPLACE FUNCTION public.correct_detection(
  p_detectionid integer,
  p_field       text,
  p_value       text,
  p_note        text DEFAULT NULL)
  RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_role     text := public.current_user_role();
  v_det      public.detection;
  v_media    public.media;
  v_cs       public.crimescene;
  v_case     public.cases;
  v_ai       text;
  v_old      text;
  v_new      text;
  v_note     text := NULLIF(trim(COALESCE(p_note, '')), '');
  v_id       integer;
  v_label    text;
BEGIN
  IF v_role IS NULL OR v_role NOT IN ('admin', 'investigator') THEN
    RAISE EXCEPTION 'Only investigators and admins can correct the AI''s findings'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_det FROM public.detection WHERE detectionid = p_detectionid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Detection % not found', p_detectionid;
  END IF;
  SELECT * INTO v_media FROM public.media WHERE mediaid = v_det.mediaid;
  SELECT * INTO v_cs FROM public.crimescene WHERE incidentid = v_media.incidentid;
  SELECT * INTO v_case FROM public.cases WHERE caseid = v_cs.caseid;

  IF v_role = 'investigator' THEN
    IF NOT public.is_assigned_to(v_cs.incidentid) THEN
      RAISE EXCEPTION 'You are not assigned to the case of this crime scene'
        USING ERRCODE = '42501';
    END IF;
    IF v_case.status = 'closed' THEN
      RAISE EXCEPTION '% is closed: ask an admin to reopen it before making corrections',
        public.case_ref(v_case.caseid);
    END IF;
  END IF;

  -- the AI must be finished with this footage, or its results could
  -- still change under the investigator
  IF v_media.processingstatus <> 'completed'
     OR (public.crime_scene_analysis(v_cs.incidentid) ->> 'status') IN ('pending', 'analysing') THEN
    RAISE EXCEPTION 'The AI is still working on the footage of %: corrections are possible once it has finished',
      public.incident_ref(v_cs.incidentid);
  END IF;

  IF p_field IS NULL OR NOT (p_field = ANY (public.correctable_fields(v_det.detectiontype))) THEN
    RAISE EXCEPTION '"%" can''t be corrected on a % (allowed: %)', COALESCE(p_field, ''),
      v_det.detectiontype, array_to_string(public.correctable_fields(v_det.detectiontype), ', ');
  END IF;

  -- clean up the new value
  v_new := NULLIF(trim(COALESCE(p_value, '')), '');
  CASE p_field
    WHEN 'dismissed' THEN
      v_new := lower(COALESCE(v_new, ''));
      IF v_new NOT IN ('true', 'false') THEN
        RAISE EXCEPTION 'dismissed must be true or false';
      END IF;
    WHEN 'plate' THEN
      v_new := public.normalize_plate(v_new);
      IF char_length(v_new) > 12 THEN
        RAISE EXCEPTION 'A number plate has at most 12 letters and digits';
      END IF;
    WHEN 'weapon_type' THEN
      v_new := replace(lower(COALESCE(v_new, 'unknown')), ' ', '_');
      IF v_new NOT IN ('handgun', 'long_gun', 'rifle', 'shotgun', 'knife', 'machete',
                       'explosive', 'other', 'unknown') THEN
        RAISE EXCEPTION 'Unknown weapon type "%"', v_new;
      END IF;
    WHEN 'make', 'model' THEN
      IF char_length(v_new) > 100 THEN
        RAISE EXCEPTION '% is too long (100 characters at most)', p_field;
      END IF;
    ELSE   -- colours, vehicle type
      v_new := lower(v_new);
      IF char_length(v_new) > 50 THEN
        RAISE EXCEPTION '% is too long (50 characters at most)', p_field;
      END IF;
  END CASE;

  IF char_length(v_note) > 500 THEN
    RAISE EXCEPTION 'The reason is too long (500 characters at most)';
  END IF;

  v_ai  := public.detection_ai_value(v_det.attributes, p_field);
  v_old := public.detection_value(v_det.attributes, v_det.corrections, p_field);
  IF v_old IS NOT DISTINCT FROM v_new THEN
    RAISE EXCEPTION 'Nothing changed: % is already "%"', p_field, COALESCE(v_old, 'none');
  END IF;

  IF p_field = 'dismissed' AND v_new = 'true' THEN
    IF v_note IS NULL THEN
      RAISE EXCEPTION 'Say why this is not a real %', v_det.detectiontype;
    END IF;
    IF v_det.suspectstatus = 'confirmed' THEN
      RAISE EXCEPTION 'This person is a confirmed suspect: undo the suspect review first';
    END IF;
  END IF;

  -- 1. the value
  UPDATE public.detection
     SET corrections = CASE WHEN v_new IS NOT DISTINCT FROM v_ai
                            THEN corrections - p_field                 -- back to the AI's
                            ELSE corrections || jsonb_build_object(p_field,
                                   CASE WHEN p_field = 'dismissed' THEN to_jsonb(v_new = 'true')
                                        ELSE to_jsonb(v_new) END) END
   WHERE detectionid = p_detectionid
  RETURNING * INTO v_det;

  -- 2. keep the detail tables (used by plate matching, list_submissions
  --    ...) the same as what counts now
  IF v_det.detectiontype = 'vehicle' AND p_field <> 'dismissed' THEN
    INSERT INTO public.vehicledetail AS t (detectionid, vehicletype, make, model, colour,
                                           platedetected, licenceplatenumber, plateconfidence)
    VALUES (p_detectionid,
            left(public.detection_value(v_det.attributes, v_det.corrections, 'vehicle_type'), 50),
            left(public.detection_value(v_det.attributes, v_det.corrections, 'make'), 100),
            left(public.detection_value(v_det.attributes, v_det.corrections, 'model'), 100),
            left(public.detection_value(v_det.attributes, v_det.corrections, 'colour'), 50),
            public.detection_value(v_det.attributes, v_det.corrections, 'plate') IS NOT NULL,
            left(public.detection_value(v_det.attributes, v_det.corrections, 'plate'), 20),
            CASE WHEN v_det.corrections ? 'plate' THEN NULL
                 ELSE LEAST(GREATEST(round(public.ai_num(v_det.attributes -> 'plate_confidence'), 4), 0), 1) END)
    ON CONFLICT (detectionid) DO UPDATE
      SET vehicletype        = EXCLUDED.vehicletype,
          make               = EXCLUDED.make,
          model              = EXCLUDED.model,
          colour             = EXCLUDED.colour,
          platedetected      = EXCLUDED.platedetected,
          licenceplatenumber = EXCLUDED.licenceplatenumber,
          plateconfidence    = CASE WHEN p_field = 'plate' THEN EXCLUDED.plateconfidence
                                    ELSE t.plateconfidence END;
  ELSIF v_det.detectiontype = 'weapon' AND p_field = 'weapon_type' THEN
    INSERT INTO public.weapondetail AS t (detectionid, weapontype)
    VALUES (p_detectionid, COALESCE(v_new, 'unknown'))
    ON CONFLICT (detectionid) DO UPDATE SET weapontype = EXCLUDED.weapontype;
  END IF;

  -- 3. the log
  INSERT INTO public.correctionlog (detectionid, correctedby, fieldname,
                                    originalvalue, correctedvalue, note)
  VALUES (p_detectionid, public.current_user_id(), p_field,
          COALESCE(v_old, ''), COALESCE(v_new, ''), v_note)
  RETURNING correctionid INTO v_id;

  -- 4. the case's combined people / vehicles / weapons follow
  IF v_cs.caseid IS NOT NULL AND v_cs.reviewstatus = 'accepted' AND v_cs.aimerged THEN
    IF p_field = 'dismissed' AND v_new = 'true' THEN
      IF v_det.caseentityid IS NOT NULL THEN
        UPDATE public.detection SET caseentityid = NULL WHERE detectionid = p_detectionid;
        PERFORM public.ai_drop_empty_entities(v_cs.caseid);
      END IF;
    ELSIF p_field = 'dismissed' THEN
      -- back in: the worker places it again (another entity or a new one)
      PERFORM public.queue_ai_job('rematch', NULL, v_cs.caseid, p_detectionid);
    END IF;
    UPDATE public.cases SET aisummarystatus = 'outdated'
     WHERE caseid = v_cs.caseid AND aisummarystatus <> 'none';
    PERFORM public.queue_ai_job('summary', NULL, v_cs.caseid);
  END IF;

  -- 5. the case history
  v_label := public.detection_label(p_detectionid);
  IF v_cs.caseid IS NOT NULL THEN
    PERFORM public.log_case_event('detection_corrected', v_cs.caseid, v_cs.incidentid,
      CASE WHEN p_field = 'dismissed' AND v_new = 'true' THEN v_label || ' marked as not a real '
                                                                || v_det.detectiontype
           WHEN p_field = 'dismissed' THEN v_label || ' restored'
           ELSE v_label || ' ' || replace(p_field, '_', ' ') || ': '
                || COALESCE(v_old, 'none') || ' → ' || COALESCE(v_new, 'none') END);
  END IF;

  RETURN jsonb_build_object('correctionid', v_id, 'field', p_field,
                            'original', v_old, 'corrected', v_new);
END;
$$;


-- ---------------------------------------------------------------------
-- 6. Crime scenes of a case, and one crime scene in full
-- ---------------------------------------------------------------------

-- The cards on the case page: one row per crime scene in the case.
-- suspects / vehicles / weapons = the most seen in any ONE clip (the same
-- person in two clips of one scene counts once), without dismissed ones
-- and without people an investigator dismissed as a suspect.
CREATE OR REPLACE FUNCTION public.list_case_crime_scenes(p_caseid integer)
  RETURNS TABLE (
    incidentid        integer,
    location          text,
    description       text,
    attacktype        varchar,
    datetime          timestamptz,
    capturedat        timestamptz,
    reviewstatus      varchar,
    mediacount        integer,
    suspects          integer,
    confirmedsuspects integer,
    vehicles          integer,
    weapons           integer,
    analysisstatus    text,
    filesdone         integer,
    filesfailed       integer,
    correctioncount   integer)
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF public.current_user_role() IS DISTINCT FROM 'admin'
     AND NOT public.is_assigned_to_case(p_caseid) THEN
    RAISE EXCEPTION 'Only admins and investigators assigned to this case can see its crime scenes'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH scene AS (
    SELECT cs.*, public.crime_scene_analysis(cs.incidentid) AS a
    FROM public.crimescene cs
    WHERE cs.caseid = p_caseid
  ),
  per_clip AS (
    SELECT m.incidentid, m.mediaid,
           count(*) FILTER (WHERE d.detectiontype = 'person'
                              AND d.suspectstatus IN ('possible', 'confirmed')) AS suspects,
           count(*) FILTER (WHERE d.detectiontype = 'person'
                              AND d.suspectstatus = 'confirmed')                AS confirmed,
           count(*) FILTER (WHERE d.detectiontype = 'vehicle')                  AS vehicles,
           count(*) FILTER (WHERE d.detectiontype = 'weapon')                   AS weapons
    FROM public.media m
    JOIN public.detection d ON d.mediaid = m.mediaid
    WHERE m.incidentid IN (SELECT s.incidentid FROM scene s)
      AND m.processingstatus = 'completed'
      AND NOT public.detection_dismissed(d.corrections)
    GROUP BY m.incidentid, m.mediaid
  )
  SELECT s.incidentid, s.location, s.description, s.attacktype, s.datetime,
         (SELECT min(m.capturetimestamp) FROM public.media m WHERE m.incidentid = s.incidentid),
         s.reviewstatus,
         (s.a ->> 'files')::integer,
         COALESCE((SELECT max(p.suspects)  FROM per_clip p WHERE p.incidentid = s.incidentid), 0)::integer,
         COALESCE((SELECT max(p.confirmed) FROM per_clip p WHERE p.incidentid = s.incidentid), 0)::integer,
         COALESCE((SELECT max(p.vehicles)  FROM per_clip p WHERE p.incidentid = s.incidentid), 0)::integer,
         COALESCE((SELECT max(p.weapons)   FROM per_clip p WHERE p.incidentid = s.incidentid), 0)::integer,
         s.a ->> 'status',
         (s.a ->> 'done')::integer,
         (s.a ->> 'failed')::integer,
         (SELECT count(*) FROM public.correctionlog c
            JOIN public.detection d ON d.detectionid = c.detectionid
            JOIN public.media m     ON m.mediaid = d.mediaid
           WHERE m.incidentid = s.incidentid)::integer
  FROM scene s
  ORDER BY COALESCE((SELECT min(m.capturetimestamp) FROM public.media m
                      WHERE m.incidentid = s.incidentid), s.datetime), s.incidentid;
END;
$$;

-- Everything the crime scene page shows, as one JSON object:
--   the scene, where the AI is with it (analysis), whether you may
--   correct, its files, every detection with each correctable field
--   ({field, ai, value, corrected}) and the corrections log (newest first).
-- Admins, and investigators assigned to its case. NULL if no such scene.
CREATE OR REPLACE FUNCTION public.get_crime_scene(p_incidentid integer)
  RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_role     text := public.current_user_role();
  v_cs       public.crimescene;
  v_case     public.cases;
  v_analysis jsonb;
  v_can      boolean;
BEGIN
  IF v_role IS DISTINCT FROM 'admin' AND NOT public.is_assigned_to(p_incidentid) THEN
    RAISE EXCEPTION 'Only admins and investigators assigned to its case can see this crime scene'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_cs FROM public.crimescene WHERE incidentid = p_incidentid;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_case FROM public.cases WHERE caseid = v_cs.caseid;

  v_analysis := public.crime_scene_analysis(p_incidentid);
  v_can := (v_analysis ->> 'status') IN ('done', 'failed')
           AND (v_role = 'admin' OR v_case.status IS DISTINCT FROM 'closed');

  RETURN jsonb_build_object(
    'incident_id',       v_cs.incidentid,
    'case_id',           v_cs.caseid,
    'case_title',        v_case.title,
    'case_closed',       COALESCE(v_case.status = 'closed', false),
    'location',          v_cs.location,
    'description',       v_cs.description,
    'attack_type',       v_cs.attacktype,
    'datetime',          v_cs.datetime,
    'captured_at',       (SELECT min(m.capturetimestamp) FROM public.media m
                           WHERE m.incidentid = p_incidentid),
    'latitude',          v_cs.latitude,
    'longitude',         v_cs.longitude,
    'gps_source',        v_cs.gpssource,
    'review_status',     v_cs.reviewstatus,
    'ai_summary',        v_cs.aisummary,
    'ai_summary_status', v_cs.aisummarystatus,
    'analysis',          v_analysis,
    'can_correct',       v_can,
    'files', COALESCE((
       SELECT jsonb_agg(jsonb_build_object(
                'media_id',       f.mediaid,
                'number',         f.n,
                'media_type',     f.mediatype,
                'storage_path',   f.storagepath,
                'status',         f.processingstatus,
                'captured_at',    f.capturetimestamp,
                'ai_description', f.aidescription) ORDER BY f.n)
       FROM (SELECT m.*, row_number() OVER (ORDER BY m.mediaid) AS n
               FROM public.media m WHERE m.incidentid = p_incidentid) f), '[]'::jsonb),
    'detections', COALESCE((
       SELECT jsonb_agg(jsonb_build_object(
                'detection_id',  x.detectionid,
                'kind',          x.detectiontype,
                'label',         initcap(x.detectiontype) || ' ' || x.n,
                'media_id',      x.mediaid,
                'clip',          x.clip,
                'first_seen',    x.firstseen,
                'last_seen',     x.lastseen,
                'confidence',    x.confidencescore,
                'crops',         x.crops,
                'dismissed',     public.detection_dismissed(x.corrections),
                'suspect_status', x.suspectstatus,
                'can_correct',   v_can AND x.processingstatus = 'completed',
                'fields', (SELECT jsonb_agg(jsonb_build_object(
                                    'field',     fld,
                                    'ai',        public.detection_ai_value(x.attributes, fld),
                                    'value',     public.detection_value(x.attributes, x.corrections, fld),
                                    'corrected', x.corrections ? fld) ORDER BY o)
                             FROM unnest(public.correctable_fields(x.detectiontype))
                                  WITH ORDINALITY AS u(fld, o)),
                'correction_count', (SELECT count(*) FROM public.correctionlog c
                                      WHERE c.detectionid = x.detectionid))
              ORDER BY CASE x.detectiontype WHEN 'person' THEN 1 WHEN 'vehicle' THEN 2 ELSE 3 END, x.n)
       FROM (SELECT d.*, m.processingstatus,
                    dense_rank() OVER (ORDER BY m.mediaid) AS clip,
                    row_number() OVER (PARTITION BY d.detectiontype
                                       ORDER BY d.mediaid, d.firstseen NULLS FIRST, d.detectionid) AS n
               FROM public.detection d
               JOIN public.media m ON m.mediaid = d.mediaid
              WHERE m.incidentid = p_incidentid) x), '[]'::jsonb),
    'corrections', COALESCE((
       SELECT jsonb_agg(jsonb_build_object(
                'correction_id', c.correctionid,
                'detection_id',  c.detectionid,
                'label',         public.detection_label(c.detectionid),
                'field',         c.fieldname,
                'original',      NULLIF(c.originalvalue, ''),
                'corrected',     NULLIF(c.correctedvalue, ''),
                'note',          c.note,
                'by',            NULLIF(trim(COALESCE(u.firstname, '') || ' ' || COALESCE(u.surname, '')), ''),
                'at',            c.correctiontimestamp)
              ORDER BY c.correctiontimestamp DESC, c.correctionid DESC)
       FROM (SELECT c.* FROM public.correctionlog c
               JOIN public.detection d ON d.detectionid = c.detectionid
               JOIN public.media m     ON m.mediaid = d.mediaid
              WHERE m.incidentid = p_incidentid
              ORDER BY c.correctiontimestamp DESC, c.correctionid DESC
              LIMIT 100) c
       LEFT JOIN public."User" u ON u.userid = c.correctedby), '[]'::jsonb));
END;
$$;


-- ---------------------------------------------------------------------
-- 7. Privileges
-- ---------------------------------------------------------------------
-- internal helpers
REVOKE ALL ON FUNCTION
  public.crime_scene_analysis(integer),
  public.detection_label(integer),
  public.detection_keep_dismissed_out()
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.crime_scene_analysis(integer),
  public.detection_label(integer)
TO service_role;

-- pure helpers (no data access)
REVOKE ALL ON FUNCTION
  public.correctable_fields(text),
  public.detection_ai_value(jsonb, text),
  public.detection_value(jsonb, jsonb, text),
  public.detection_dismissed(jsonb)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.correctable_fields(text),
  public.detection_ai_value(jsonb, text),
  public.detection_value(jsonb, jsonb, text),
  public.detection_dismissed(jsonb)
TO authenticated, service_role;

-- for the app (each checks who is asking)
REVOKE ALL ON FUNCTION
  public.correct_detection(integer, text, text, text),
  public.list_case_crime_scenes(integer),
  public.get_crime_scene(integer)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.correct_detection(integer, text, text, text),
  public.list_case_crime_scenes(integer),
  public.get_crime_scene(integer)
TO authenticated, service_role;
