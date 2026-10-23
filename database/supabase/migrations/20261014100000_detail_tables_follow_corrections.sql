-- Keep vehicledetail / weapondetail in step with detection_value(), including
-- after a correction or an undone correction.
--
-- The bug: ai_save_analysis (20261012100100 section 6) skipped the detail
-- rows for any detection that had ever been corrected. So after a correction,
-- or even one that got undone, re-runs stopped refreshing them and they
-- drifted away from detection_value(). That matters because plate matching
-- and list_submissions read vehicledetail.
--
-- The fix:
--   - ai_save_analysis always writes the detail rows from detection_value(),
--     so a corrected field keeps the investigator's value and the rest follow
--     the new run. vehicledetail.model gets filled in too.
--     weapondetail.heldbydetectionid still comes from the run.
--   - detection_ai_value('weapon_type') maps classes weapondetail doesn't know
--     (like 'pistol') to 'other', same as ai_save_analysis always did, so the
--     scene page and weapondetail agree.
--   - existing rows get fixed up once at the bottom.


-- --- 1. what the AI said for a field (NULL if it didn't say)
-- Same as 20261013100000 section 3, except weapon classes weapondetail
-- doesn't know come out as 'other'.
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
    WHEN 'weapon_type'    THEN
      CASE WHEN NULLIF(lower(p_attributes ->> 'class_name'), '') IS NULL THEN NULL
           WHEN lower(p_attributes ->> 'class_name') IN ('handgun', 'long_gun', 'rifle', 'shotgun',
                                                         'knife', 'machete', 'explosive', 'other',
                                                         'unknown')
           THEN lower(p_attributes ->> 'class_name')
           ELSE 'other' END
    WHEN 'dismissed'      THEN 'false'
  END
$$;


-- --- 2. ai_save_analysis: same as 20261012100100 section 6, except the
-- detail rows always come from detection_value()
CREATE OR REPLACE FUNCTION public.ai_save_analysis(
  p_incidentid integer, p_result jsonb, p_summary text DEFAULT NULL)
  RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_cs       public.crimescene;
  v_file     jsonb;
  v_det      jsonb;
  v_n        integer;
  v_mediaid  integer;
  v_kind     text;
  v_detid    integer;
  v_keep     integer[];
  v_all      integer[] := '{}';
  v_removed  integer := 0;
  v_files    integer := 0;
  v_lat      numeric;
  v_lon      numeric;
  v_attrs    jsonb;
  v_corr     jsonb;
BEGIN
  IF p_result IS NULL OR jsonb_typeof(p_result -> 'files') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'p_result must be a results.json object with a "files" list';
  END IF;

  SELECT * INTO v_cs FROM public.crimescene WHERE incidentid = p_incidentid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Incident % not found', p_incidentid;
  END IF;

  -- re-analysed after it was already merged into a case: take the old
  -- results out first, finish_job will queue a fresh merge
  IF v_cs.aimerged AND v_cs.caseid IS NOT NULL THEN
    PERFORM public.ai_unmerge_incident(p_incidentid, v_cs.caseid);
  END IF;

  FOR v_file, v_n IN
    SELECT f, n::integer FROM jsonb_array_elements(p_result -> 'files') WITH ORDINALITY AS x(f, n)
  LOOP
    v_mediaid := CASE WHEN jsonb_typeof(v_file -> 'mediaid') = 'number'
                      THEN (v_file ->> 'mediaid')::integer END;
    IF v_mediaid IS NULL OR NOT EXISTS (
         SELECT 1 FROM public.media WHERE mediaid = v_mediaid AND incidentid = p_incidentid) THEN
      RAISE EXCEPTION 'File % of results.json: "mediaid" % is not a file of incident %',
        v_n, COALESCE(v_file ->> 'mediaid', 'missing'), p_incidentid;
    END IF;
    v_files := v_files + 1;

    IF v_file ? 'error' THEN                 -- the pipeline couldn't handle this file
      UPDATE public.media SET processingstatus = 'failed' WHERE mediaid = v_mediaid;
      CONTINUE;
    END IF;

    v_lat := public.ai_num(v_file -> 'latitude');
    v_lon := public.ai_num(v_file -> 'longitude');
    IF v_lat NOT BETWEEN -90 AND 90 OR v_lon NOT BETWEEN -180 AND 180
       OR v_lat IS NULL OR v_lon IS NULL THEN
      v_lat := NULL; v_lon := NULL;
    END IF;

    UPDATE public.media
       SET processingstatus = 'completed',
           capturetimestamp = COALESCE(public.ai_try_timestamptz(v_file ->> 'capture_time'),
                                       capturetimestamp),
           latitude  = COALESCE(round(v_lat, 6), latitude),
           longitude = COALESCE(round(v_lon, 6), longitude)
     WHERE mediaid = v_mediaid;

    -- people first, because weapons point at whoever is holding them
    v_keep := '{}';
    FOR v_det IN
      SELECT d FROM jsonb_array_elements(COALESCE(v_file -> 'detections', '[]'::jsonb))
             WITH ORDINALITY AS x(d, n)
      ORDER BY CASE d ->> 'detection_type' WHEN 'person' THEN 1 WHEN 'vehicle' THEN 2 ELSE 3 END, n
    LOOP
      v_kind := v_det ->> 'detection_type';
      IF v_kind IS NULL OR v_kind NOT IN ('person', 'vehicle', 'weapon')
         OR jsonb_typeof(v_det -> 'track_id') IS DISTINCT FROM 'number' THEN
        RAISE EXCEPTION 'File % of results.json: every detection needs detection_type person/vehicle/weapon and a track_id', v_n;
      END IF;

      INSERT INTO public.detection AS t (
        mediaid, detectiontype, trackid, frametimestamp, boundingbox, confidencescore,
        modelversion, firstseen, lastseen, framesseen, attributes, crops, appearance, colourhist)
      VALUES (
        v_mediaid, v_kind, (v_det ->> 'track_id')::integer,
        round(public.ai_num(v_det -> 'frame_time_seconds'), 3),
        v_det -> 'bounding_box',
        LEAST(GREATEST(round(public.ai_num(v_det -> 'confidence'), 4), 0), 1),
        left(COALESCE(v_det ->> 'model_version', p_result ->> 'model_version'), 200),
        round(public.ai_num(v_det -> 'first_seen_seconds'), 3),
        round(GREATEST(public.ai_num(v_det -> 'last_seen_seconds'),
                       public.ai_num(v_det -> 'first_seen_seconds')), 3),
        public.ai_num(v_det -> 'frames_seen')::integer,
        -- everything else the AI said (paths and fingerprints have their own columns)
        v_det - ARRAY['track_id', 'detection_type', 'bounding_box', 'confidence',
                      'first_seen_seconds', 'last_seen_seconds', 'frames_seen',
                      'model_version', 'appearance', 'person_crop_path', 'face_crop_path',
                      'crop_path', 'plate_crop_path', 'extra_crop_paths',
                      'frame_number', 'frame_time_seconds'],
        public.ai_crops(v_det, p_incidentid),
        public.ai_vector(v_det -> 'appearance' -> 'embedding', 512),
        public.ai_vector(v_det -> 'appearance' -> 'colour_hist', 96))
      ON CONFLICT (mediaid, detectiontype, trackid) DO UPDATE
        SET frametimestamp  = EXCLUDED.frametimestamp,
            boundingbox     = EXCLUDED.boundingbox,
            confidencescore = EXCLUDED.confidencescore,
            modelversion    = EXCLUDED.modelversion,
            firstseen       = EXCLUDED.firstseen,
            lastseen        = EXCLUDED.lastseen,
            framesseen      = EXCLUDED.framesseen,
            attributes      = EXCLUDED.attributes,
            crops           = EXCLUDED.crops,
            appearance      = EXCLUDED.appearance,
            colourhist      = EXCLUDED.colourhist
      RETURNING detectionid, attributes, corrections INTO v_detid, v_attrs, v_corr;
      v_keep := v_keep || v_detid;

      -- details from detection_value(), so a corrected field keeps the
      -- investigator's value and everything else follows this run
      IF v_kind = 'vehicle' THEN
        INSERT INTO public.vehicledetail (detectionid, vehicletype, make, model, colour,
                                          platedetected, licenceplatenumber, plateconfidence)
        VALUES (v_detid,
                left(public.detection_value(v_attrs, v_corr, 'vehicle_type'), 50),
                left(public.detection_value(v_attrs, v_corr, 'make'), 100),
                left(public.detection_value(v_attrs, v_corr, 'model'), 100),
                left(public.detection_value(v_attrs, v_corr, 'colour'), 50),
                public.detection_value(v_attrs, v_corr, 'plate') IS NOT NULL,
                left(public.detection_value(v_attrs, v_corr, 'plate'), 20),
                -- a corrected plate has no AI confidence (same as correct_detection)
                CASE WHEN v_corr ? 'plate' THEN NULL
                     ELSE LEAST(GREATEST(round(public.ai_num(v_det -> 'plate_confidence'), 4), 0), 1) END)
        ON CONFLICT (detectionid) DO UPDATE
          SET vehicletype        = EXCLUDED.vehicletype,
              make               = EXCLUDED.make,
              model              = EXCLUDED.model,
              colour             = EXCLUDED.colour,
              platedetected      = EXCLUDED.platedetected,
              licenceplatenumber = EXCLUDED.licenceplatenumber,
              plateconfidence    = EXCLUDED.plateconfidence;
      ELSIF v_kind = 'weapon' THEN
        INSERT INTO public.weapondetail (detectionid, weapontype, heldbydetectionid)
        VALUES (v_detid,
                COALESCE(public.detection_value(v_attrs, v_corr, 'weapon_type'), 'unknown'),
                (SELECT p.detectionid FROM public.detection p
                  WHERE p.mediaid = v_mediaid AND p.detectiontype = 'person'
                    AND p.trackid = public.ai_num(v_det -> 'held_by_person')))
        ON CONFLICT (detectionid) DO UPDATE
          SET weapontype        = EXCLUDED.weapontype,
              heldbydetectionid = EXCLUDED.heldbydetectionid;
      END IF;
    END LOOP;

    -- rows from an earlier run that this run doesn't have and nobody has touched
    WITH stale AS (
      SELECT d.detectionid FROM public.detection d
      WHERE d.mediaid = v_mediaid
        AND d.detectionid <> ALL (v_keep)
        AND NOT d.verified
        AND COALESCE(d.suspectstatus, 'possible') = 'possible'
        AND NOT EXISTS (SELECT 1 FROM public.correctionlog c WHERE c.detectionid = d.detectionid)
        AND NOT EXISTS (SELECT 1 FROM public.suspect s WHERE s.detectionid = d.detectionid)
    ),
    v AS (DELETE FROM public.vehicledetail x USING stale WHERE x.detectionid = stale.detectionid),
    w AS (DELETE FROM public.weapondetail x USING stale WHERE x.detectionid = stale.detectionid),
    gone AS (DELETE FROM public.detection x USING stale
              WHERE x.detectionid = stale.detectionid RETURNING 1)
    SELECT v_removed + count(*) INTO v_removed FROM gone;

    v_all := v_all || v_keep;
  END LOOP;

  -- location: GPS from the files beats the phone's
  v_lat := public.ai_num(p_result -> 'location' -> 'latitude');
  v_lon := public.ai_num(p_result -> 'location' -> 'longitude');
  IF COALESCE(p_result -> 'location' ->> 'source', 'file') = 'file'
     AND v_lat BETWEEN -90 AND 90 AND v_lon BETWEEN -180 AND 180 THEN
    UPDATE public.crimescene
       SET latitude = round(v_lat, 6), longitude = round(v_lon, 6), gpssource = 'file'
     WHERE incidentid = p_incidentid;
  ELSE
    UPDATE public.crimescene
       SET gpssource = COALESCE(gpssource, CASE WHEN latitude IS NOT NULL THEN 'phone' ELSE 'typed' END)
     WHERE incidentid = p_incidentid;
  END IF;

  IF NULLIF(trim(COALESCE(p_summary, '')), '') IS NOT NULL THEN
    UPDATE public.crimescene
       SET aisummary = left(trim(p_summary), 600), aisummarystatus = 'ready', aisummaryat = now()
     WHERE incidentid = p_incidentid;
  END IF;

  RETURN jsonb_build_object(
    'files', v_files,
    'detections', cardinality(v_all),
    'people',   (SELECT count(*) FROM public.detection WHERE detectionid = ANY (v_all) AND detectiontype = 'person'),
    'vehicles', (SELECT count(*) FROM public.detection WHERE detectionid = ANY (v_all) AND detectiontype = 'vehicle'),
    'weapons',  (SELECT count(*) FROM public.detection WHERE detectionid = ANY (v_all) AND detectiontype = 'weapon'),
    'removed', v_removed);
END;
$$;


-- --- 3. fix up existing data

-- A weapon_type correction to 'other' on a class that now reads 'other'
-- anyway isn't a correction any more. corrections only holds keys that differ
-- from the AI, and the log still has the history.
UPDATE public.detection
   SET corrections = corrections - 'weapon_type'
 WHERE detectiontype = 'weapon'
   AND corrections ? 'weapon_type'
   AND corrections ->> 'weapon_type' IS NOT DISTINCT FROM
       public.detection_ai_value(attributes, 'weapon_type');

-- detail rows that drifted get reset to the current value
UPDATE public.vehicledetail vd
   SET vehicletype        = left(public.detection_value(d.attributes, d.corrections, 'vehicle_type'), 50),
       make               = left(public.detection_value(d.attributes, d.corrections, 'make'), 100),
       model              = left(public.detection_value(d.attributes, d.corrections, 'model'), 100),
       colour             = left(public.detection_value(d.attributes, d.corrections, 'colour'), 50),
       platedetected      = public.detection_value(d.attributes, d.corrections, 'plate') IS NOT NULL,
       licenceplatenumber = left(public.detection_value(d.attributes, d.corrections, 'plate'), 20),
       plateconfidence    = CASE WHEN d.corrections ? 'plate' THEN NULL
                                 ELSE LEAST(GREATEST(round(public.ai_num(d.attributes -> 'plate_confidence'), 4), 0), 1) END
  FROM public.detection d
 WHERE d.detectionid = vd.detectionid
   AND d.detectiontype = 'vehicle';

UPDATE public.weapondetail wd
   SET weapontype = COALESCE(public.detection_value(d.attributes, d.corrections, 'weapon_type'), 'unknown')
  FROM public.detection d
 WHERE d.detectionid = wd.detectionid
   AND d.detectiontype = 'weapon';
