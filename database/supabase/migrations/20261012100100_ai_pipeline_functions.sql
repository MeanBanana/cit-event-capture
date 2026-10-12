-- =====================================================================
-- Argus Shield: AI pipeline in the database - FUNCTIONS AND TRIGGERS
-- (docs: SUPABASE_AI_PIPELINE.md; tables in 20261012100000_ai_pipeline_tables.sql)
--
--   Citizen app                Database                         AI worker (service key)
--   upload 1-5 files
--   submit_for_analysis(42) -> aijob 'analyse' 42
--                                                 <- claim_next_job('gpu-1')
--                                                    run pipeline, upload crops
--                              detection rows    <- ai_save_analysis(42, results.json)
--                                                 <- finish_job(jobid)
--   Admin accepts           -> crimescene.caseid = 7
--                              trigger: aijob 'merge' 42 -> 7
--                                                 <- claim_next_job
--                                                 <- ai_load_case(7), ai_load_submission(42)
--                                                    case_matcher.merge_submission()
--                              caseentity, links <- ai_save_case(7, case)
--   Admin opens the case    -> get_case_evidence(7)
--   "Is this Person 2?"     -> answer_entity_match(detectionid, yes/no)
--                              (No -> aijob 'rematch')
--
-- Why the worker writes through functions instead of plain inserts: each
-- save is ONE transaction (a re-run never leaves half old / half new rows,
-- which separate REST calls can't guarantee), and the database checks the
-- data (right incident, pictures in that incident's ai/ folder, human
-- decisions never overwritten).
--
-- Who may call what
--   citizen (own incident) / admin   submit_for_analysis
--   admin                            answer_entity_match, ai_worker_status
--   admin / assigned investigator    get_case_evidence
--   worker (service key) only        claim_next_job, finish_job,
--                                    ai_worker_heartbeat, ai_save_analysis,
--                                    ai_load_case, ai_load_submission,
--                                    ai_save_case
--
-- Contents
--   1. Small helpers              7. Worker: save a case's people/vehicles/weapons
--   2. Queue helpers              8. Triggers: case membership, protection
--   3. submit_for_analysis        9. get_case_evidence
--   4. claim_next_job, finish_job 10. answer_entity_match
--   5. Worker heartbeat / status  11. list_cases + AI summary
--   6. Worker: save an analysis   12. Privileges
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Small helpers (results.json values -> column values, never failing)
-- ---------------------------------------------------------------------

-- '2026-10-08T17:01:55+02:00' -> timestamptz; NULL for anything unreadable
CREATE OR REPLACE FUNCTION public.ai_try_timestamptz(p_text text)
  RETURNS timestamptz
  LANGUAGE plpgsql STABLE
  SET search_path = ''
AS $$
BEGIN
  RETURN NULLIF(trim(p_text), '')::timestamptz;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;

-- JSON number -> numeric (NULL for anything else)
CREATE OR REPLACE FUNCTION public.ai_num(p_value jsonb)
  RETURNS numeric
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$
  SELECT CASE WHEN jsonb_typeof(p_value) = 'number' THEN p_value::text::numeric END
$$;

-- JSON list of p_dims numbers -> pgvector (NULL when missing or wrong size)
CREATE OR REPLACE FUNCTION public.ai_vector(p_value jsonb, p_dims integer)
  RETURNS extensions.vector
  LANGUAGE plpgsql IMMUTABLE
  SET search_path = ''
AS $$
BEGIN
  IF jsonb_typeof(p_value) = 'array' AND jsonb_array_length(p_value) = p_dims THEN
    RETURN p_value::text::extensions.vector;
  END IF;
  RETURN NULL;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;

-- How alike two appearance fingerprints are, about 0-1 (NULL if one is
-- missing). Same formula as ai/appearance.py similarity():
-- 0.7 x cosine(embedding) + 0.3 x cosine(colour_hist).
CREATE OR REPLACE FUNCTION public.appearance_similarity(
  p_emb_a extensions.vector, p_hist_a extensions.vector,
  p_emb_b extensions.vector, p_hist_b extensions.vector)
  RETURNS double precision
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$
  WITH c AS (
    SELECT 1 - (p_emb_a  OPERATOR(extensions.<=>) p_emb_b)  AS emb,
           1 - (p_hist_a OPERATOR(extensions.<=>) p_hist_b) AS col
  )
  SELECT CASE WHEN c.emb IS NULL THEN c.col
              WHEN c.col IS NULL THEN c.emb
              ELSE 0.7 * c.emb + 0.3 * c.col END
  FROM c
$$;

-- The pictures of one results.json detection as [{path, type}], in the
-- same order as ai/case_matcher.py _member(). Only paths inside the
-- incident's own ai/ folder are kept (upload_results.py puts them there),
-- so a detection can never point at another incident's files.
CREATE OR REPLACE FUNCTION public.ai_crops(p_det jsonb, p_incidentid integer)
  RETURNS jsonb
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$
  WITH pics(n, path, type) AS (
    SELECT 1, p_det ->> 'person_crop_path', 'person'
      WHERE p_det ->> 'detection_type' = 'person'
    UNION ALL
    SELECT 2, p_det ->> 'face_crop_path', 'face'
      WHERE p_det ->> 'detection_type' = 'person'
    UNION ALL
    SELECT 1, p_det ->> 'crop_path',
           CASE p_det ->> 'detection_type' WHEN 'vehicle' THEN 'vehicle' ELSE 'weapon' END
      WHERE p_det ->> 'detection_type' IN ('vehicle', 'weapon')
    UNION ALL
    SELECT 2, p_det ->> 'plate_crop_path', 'plate'
      WHERE p_det ->> 'detection_type' = 'vehicle'
    UNION ALL
    SELECT 2 + x.n::integer, x.path,
           CASE p_det ->> 'detection_type' WHEN 'person' THEN 'person' ELSE 'vehicle' END
      FROM jsonb_array_elements_text(
             CASE WHEN jsonb_typeof(p_det -> 'extra_crop_paths') = 'array'
                  THEN p_det -> 'extra_crop_paths' ELSE '[]'::jsonb END)
           WITH ORDINALITY AS x(path, n)
      WHERE p_det ->> 'detection_type' IN ('person', 'vehicle')
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('path', path, 'type', type) ORDER BY n), '[]'::jsonb)
  FROM pics
  WHERE path LIKE p_incidentid || '/ai/%'
    AND path NOT LIKE '%..%'
$$;

-- "top black, bottom blue · face seen" - same text as case_matcher.describe()
CREATE OR REPLACE FUNCTION public.ai_entity_description(p_kind text, p_attributes jsonb)
  RETURNS text
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$
  WITH a AS (
    SELECT NULLIF(p_attributes ->> 'upper_clothing', '') AS upper,
           NULLIF(p_attributes ->> 'lower_clothing', '') AS lower,
           COALESCE(p_attributes -> 'face_visible' = 'true'::jsonb, false) AS face,
           NULLIF(concat_ws(' ', NULLIF(p_attributes ->> 'colour', ''),
                                 NULLIF(p_attributes ->> 'make', ''),
                                 NULLIF(p_attributes ->> 'class_name', '')), '') AS look,
           NULLIF(p_attributes ->> 'plate', '') AS plate,
           COALESCE(public.ai_num(p_attributes -> 'plate_seen_in'), 1) AS seen,
           replace(COALESCE(NULLIF(p_attributes ->> 'kind', ''), 'unsure'), '_', ' ') AS weapon,
           NULLIF(p_attributes ->> 'held_by', '') AS held_by
  )
  SELECT CASE p_kind
    WHEN 'person' THEN concat_ws(' · ',
      CASE WHEN a.upper IS NOT NULL OR a.lower IS NOT NULL
           THEN 'top ' || COALESCE(a.upper, 'unsure') || ', bottom ' || COALESCE(a.lower, 'unsure') END,
      CASE WHEN a.face THEN 'face seen' ELSE 'no clear face' END)
    WHEN 'vehicle' THEN COALESCE(a.look, 'vehicle') || ' · ' ||
      CASE WHEN a.plate IS NOT NULL
           THEN 'plate ' || a.plate
                || CASE WHEN a.seen > 1 THEN ' (read in ' || a.seen || ' submissions)' ELSE '' END
           ELSE 'no readable plate' END
    ELSE a.weapon || COALESCE(' · held by ' || a.held_by, '')
  END
  FROM a
$$;

-- 'p2' / 'Person 2' for an entity
CREATE OR REPLACE FUNCTION public.ai_entity_key(p_kind text, p_number integer)
  RETURNS text
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$ SELECT left(p_kind, 1) || p_number $$;

CREATE OR REPLACE FUNCTION public.ai_entity_label(p_kind text, p_number integer)
  RETURNS text
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$ SELECT initcap(p_kind) || ' ' || p_number $$;


-- ---------------------------------------------------------------------
-- 2. Queue helpers (internal: only used by the functions below)
-- ---------------------------------------------------------------------

-- Queue a job unless the same one is already waiting. Returns its id.
CREATE OR REPLACE FUNCTION public.queue_ai_job(
  p_kind        text,
  p_incidentid  integer DEFAULT NULL,
  p_caseid      integer DEFAULT NULL,
  p_detectionid integer DEFAULT NULL)
  RETURNS bigint
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_id bigint;
BEGIN
  INSERT INTO public.aijob (kind, incidentid, caseid, detectionid)
  VALUES (p_kind, p_incidentid, p_caseid, p_detectionid)
  ON CONFLICT (kind, COALESCE(incidentid, 0), COALESCE(caseid, 0), COALESCE(detectionid, 0))
    WHERE status = 'queued'
    DO NOTHING
  RETURNING jobid INTO v_id;

  IF v_id IS NULL THEN                       -- already waiting
    SELECT j.jobid INTO v_id FROM public.aijob j
    WHERE j.status = 'queued' AND j.kind = p_kind
      AND j.incidentid  IS NOT DISTINCT FROM p_incidentid
      AND j.caseid      IS NOT DISTINCT FROM p_caseid
      AND j.detectionid IS NOT DISTINCT FROM p_detectionid;
  END IF;
  RETURN v_id;
END;
$$;

-- A running job went wrong (error reported, or its worker stopped
-- answering). Back in the queue while attempts < 3, else 'failed' - and
-- then the app is told: "AI analysis failed" / the case summary failed.
CREATE OR REPLACE FUNCTION public.ai_job_failed(p_jobid bigint, p_error text)
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_job public.aijob;
  v_newer boolean;
BEGIN
  SELECT * INTO v_job FROM public.aijob WHERE jobid = p_jobid FOR UPDATE;

  -- the same work was queued again meanwhile: that one will do it
  v_newer := EXISTS (
    SELECT 1 FROM public.aijob q
    WHERE q.status = 'queued' AND q.jobid <> v_job.jobid AND q.kind = v_job.kind
      AND q.incidentid  IS NOT DISTINCT FROM v_job.incidentid
      AND q.caseid      IS NOT DISTINCT FROM v_job.caseid
      AND q.detectionid IS NOT DISTINCT FROM v_job.detectionid);

  IF v_job.attempts < 3 AND NOT v_newer THEN
    UPDATE public.aijob
       SET status = 'queued', error = p_error, workerid = NULL, finishedat = now()
     WHERE jobid = p_jobid;
    RETURN;
  END IF;

  UPDATE public.aijob
     SET status = 'failed', finishedat = now(),
         error = p_error || CASE WHEN v_newer THEN ' (a newer queued job will redo this)' ELSE '' END
   WHERE jobid = p_jobid;
  IF v_newer THEN
    RETURN;
  END IF;

  IF v_job.kind = 'analyse' THEN
    UPDATE public.media SET processingstatus = 'failed'
     WHERE incidentid = v_job.incidentid AND processingstatus IN ('pending', 'processing');
    UPDATE public.crimescene SET aisummarystatus = 'failed'
     WHERE incidentid = v_job.incidentid AND aisummarystatus = 'processing';
  ELSE
    UPDATE public.cases SET aisummarystatus = 'failed' WHERE caseid = v_job.caseid;
  END IF;
END;
$$;

-- Entities left without any settled picture (first / auto / confirmed) are
-- removed. Their open questions go back to the worker ('rematch').
CREATE OR REPLACE FUNCTION public.ai_drop_empty_entities(p_caseid integer)
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_detectionid integer;
BEGIN
  FOR v_detectionid IN
    SELECT d.detectionid
    FROM public.caseentity e
    JOIN public.detection d ON d.caseentityid = e.entityid
    WHERE e.caseid = p_caseid AND d.matchstatus = 'suggested'
      AND NOT EXISTS (SELECT 1 FROM public.detection s
                       WHERE s.caseentityid = e.entityid
                         AND s.matchstatus IN ('first', 'auto', 'confirmed'))
  LOOP
    PERFORM public.queue_ai_job('rematch', NULL, p_caseid, v_detectionid);
  END LOOP;

  DELETE FROM public.caseentity e
  WHERE e.caseid = p_caseid
    AND NOT EXISTS (SELECT 1 FROM public.detection s
                     WHERE s.caseentityid = e.entityid
                       AND s.matchstatus IN ('first', 'auto', 'confirmed'));
END;
$$;

-- A submission leaves its case (removed, moved, rejected, re-analysed):
-- its pictures are taken out of the case's people / vehicles / weapons
-- straight away, entities left empty are deleted, and the worker re-votes
-- the rest ('summary'). Without this a removed submission's crops would
-- stay under "Person 1".
CREATE OR REPLACE FUNCTION public.ai_unmerge_incident(p_incidentid integer, p_caseid integer)
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  UPDATE public.detection d
     SET caseentityid = NULL               -- detection_clear_match clears the rest
    FROM public.media m, public.caseentity e
   WHERE m.mediaid = d.mediaid AND m.incidentid = p_incidentid
     AND e.entityid = d.caseentityid AND e.caseid = p_caseid;

  UPDATE public.crimescene SET aimerged = false
   WHERE incidentid = p_incidentid AND aimerged;

  -- The whole case is being deleted (release_case_incidents): nothing to
  -- tidy up, and its row can't be changed while it is being deleted.
  IF current_setting('argus.deleting_case', true) = p_caseid::text THEN
    RETURN;
  END IF;

  PERFORM public.ai_drop_empty_entities(p_caseid);
  UPDATE public.cases SET aisummarystatus = 'outdated'
   WHERE caseid = p_caseid AND aisummarystatus <> 'none';
  PERFORM public.queue_ai_job('summary', NULL, p_caseid);
END;
$$;


-- ---------------------------------------------------------------------
-- 3. submit_for_analysis - called by the citizen app after the LAST file
--    of a submission is uploaded (a trigger on media would start the
--    analysis after the first of up to 5 files).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_for_analysis(p_incidentid integer)
  RETURNS bigint                             -- the job id
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_files integer;
  v_job   bigint;
BEGIN
  IF public.current_user_role() IS DISTINCT FROM 'admin'
     AND NOT COALESCE(public.reported_by_me(p_incidentid), false) THEN
    RAISE EXCEPTION 'Only the person who reported this incident (or an admin) can submit it for analysis'
      USING ERRCODE = '42501';
  END IF;

  -- one submit at a time per incident (double taps)
  PERFORM 1 FROM public.crimescene WHERE incidentid = p_incidentid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Incident % not found', p_incidentid;
  END IF;

  SELECT count(*) INTO v_files FROM public.media WHERE incidentid = p_incidentid;
  IF v_files = 0 THEN
    RAISE EXCEPTION 'Upload at least one file before submitting for analysis';
  ELSIF v_files > 5 THEN
    RAISE EXCEPTION 'A submission can have at most 5 files (incident % has %)', p_incidentid, v_files;
  END IF;

  -- already waiting or being analysed: nothing more to do
  SELECT j.jobid INTO v_job FROM public.aijob j
  WHERE j.kind = 'analyse' AND j.incidentid = p_incidentid
    AND j.status IN ('queued', 'processing')
  ORDER BY j.jobid LIMIT 1;
  IF v_job IS NOT NULL THEN
    RETURN v_job;
  END IF;

  UPDATE public.media SET processingstatus = 'pending' WHERE incidentid = p_incidentid;
  UPDATE public.crimescene SET aisummarystatus = 'processing' WHERE incidentid = p_incidentid;
  RETURN public.queue_ai_job('analyse', p_incidentid);
END;
$$;


-- ---------------------------------------------------------------------
-- 4. The worker takes and finishes jobs
-- ---------------------------------------------------------------------

-- Oldest queued job, or no row when there is nothing to do. Safe with
-- several workers: claims happen one at a time, and a job is skipped
-- while another job for the same case or incident is running (two merges
-- into one case at once would overwrite each other).
-- Also puts back jobs whose worker died, max 3 attempts. "Died" = running
-- for more than 60 min AND no heartbeat from its worker for 2 min (a long
-- analysis on a live worker is left alone), running for over 6 hours, or
-- the same worker asking for a new job (one job at a time per worker id).
CREATE OR REPLACE FUNCTION public.claim_next_job(p_workerid text)
  RETURNS SETOF public.aijob
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_jobid bigint;
  v_job   public.aijob;
BEGIN
  IF NULLIF(trim(COALESCE(p_workerid, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Give the worker an id (e.g. the machine name)';
  END IF;

  -- claims take milliseconds; one at a time keeps the "nothing else is
  -- running for this case" check below exact
  PERFORM pg_advisory_xact_lock(hashtext('public.claim_next_job'));

  -- a worker does one job at a time: if it asks for a new one, the job it
  -- still has open was lost (it crashed and started again)
  FOR v_jobid IN
    SELECT j.jobid FROM public.aijob j
    WHERE j.status = 'processing' AND j.workerid = p_workerid
    ORDER BY j.jobid
  LOOP
    PERFORM public.ai_job_failed(v_jobid, 'the worker started again before finishing this job');
  END LOOP;

  FOR v_jobid IN
    SELECT j.jobid FROM public.aijob j
    WHERE j.status = 'processing'
      AND (   (j.startedat < now() - interval '60 minutes'
               AND NOT EXISTS (SELECT 1 FROM public.aiworker w
                                WHERE w.workerid = j.workerid
                                  AND w.lastseen > now() - interval '2 minutes'))
           OR j.startedat < now() - interval '6 hours')
    ORDER BY j.jobid
  LOOP
    PERFORM public.ai_job_failed(v_jobid, 'timed out: its worker stopped sending heartbeats');
  END LOOP;

  INSERT INTO public.aiworker AS w (workerid, lastseen) VALUES (p_workerid, now())
  ON CONFLICT (workerid) DO UPDATE SET lastseen = now();

  SELECT j.jobid INTO v_jobid
  FROM public.aijob j
  WHERE j.status = 'queued'
    AND NOT EXISTS (
      SELECT 1 FROM public.aijob p
      WHERE p.status = 'processing'
        AND ((j.caseid IS NOT NULL AND p.caseid = j.caseid)
          OR (j.incidentid IS NOT NULL AND p.incidentid = j.incidentid)))
  ORDER BY j.createdat, j.jobid
  LIMIT 1
  FOR UPDATE SKIP LOCKED;

  IF v_jobid IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.aijob
     SET status = 'processing', startedat = now(), finishedat = NULL,
         attempts = attempts + 1, workerid = p_workerid
   WHERE jobid = v_jobid
  RETURNING * INTO v_job;

  IF v_job.kind = 'analyse' THEN
    UPDATE public.media SET processingstatus = 'processing'
     WHERE incidentid = v_job.incidentid AND processingstatus = 'pending';
  END IF;

  RETURN NEXT v_job;
END;
$$;

-- The worker is done with a job: no error -> 'done'; an error -> back in
-- the queue (attempts < 3) or 'failed'.
CREATE OR REPLACE FUNCTION public.finish_job(p_jobid bigint, p_error text DEFAULT NULL)
  RETURNS public.aijob
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_job public.aijob;
  v_cs  public.crimescene;
BEGIN
  SELECT * INTO v_job FROM public.aijob WHERE jobid = p_jobid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Job % not found', p_jobid;
  ELSIF v_job.status <> 'processing' THEN
    RAISE EXCEPTION 'Job % is not running (status %)', p_jobid, v_job.status;
  END IF;

  IF NULLIF(trim(COALESCE(p_error, '')), '') IS NOT NULL THEN
    PERFORM public.ai_job_failed(p_jobid, left(p_error, 2000));
    SELECT * INTO v_job FROM public.aijob WHERE jobid = p_jobid;
    RETURN v_job;
  END IF;

  UPDATE public.aijob SET status = 'done', finishedat = now(), error = NULL
   WHERE jobid = p_jobid
  RETURNING * INTO v_job;

  IF v_job.kind = 'analyse' THEN
    -- files the run didn't report on were not analysed
    UPDATE public.media SET processingstatus = 'failed'
     WHERE incidentid = v_job.incidentid AND processingstatus IN ('pending', 'processing');
    UPDATE public.crimescene
       SET aisummarystatus = CASE WHEN aisummary IS NULL THEN 'none' ELSE 'ready' END
     WHERE incidentid = v_job.incidentid AND aisummarystatus = 'processing';

    -- already accepted into a case: combine the new results into it
    SELECT * INTO v_cs FROM public.crimescene WHERE incidentid = v_job.incidentid;
    IF v_cs.caseid IS NOT NULL AND v_cs.reviewstatus = 'accepted' AND NOT v_cs.aimerged THEN
      PERFORM public.queue_ai_job('merge', v_cs.incidentid, v_cs.caseid);
    END IF;
  END IF;
  RETURN v_job;
END;
$$;


-- ---------------------------------------------------------------------
-- 5. Worker heartbeat and status
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ai_worker_heartbeat(
  p_workerid text, p_gpu text DEFAULT NULL, p_version text DEFAULT NULL)
  RETURNS void
  LANGUAGE sql SECURITY DEFINER
  SET search_path = ''
AS $$
  INSERT INTO public.aiworker (workerid, lastseen, gpu, version)
  VALUES (p_workerid, now(), p_gpu, p_version)
  ON CONFLICT (workerid) DO UPDATE
    SET lastseen = now(),
        gpu      = COALESCE(EXCLUDED.gpu, public.aiworker.gpu),
        version  = COALESCE(EXCLUDED.version, public.aiworker.version)
$$;

-- For the admin Overview: "AI worker online (RTX 3080, last seen 10 s ago)".
-- online = a heartbeat in the last 90 s (the worker sends one every ~30 s).
CREATE OR REPLACE FUNCTION public.ai_worker_status()
  RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_workers jsonb;
BEGIN
  PERFORM public.require_admin();

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'workerid', w.workerid, 'gpu', w.gpu, 'version', w.version,
           'lastseen', w.lastseen,
           'seconds_ago', GREATEST(0, floor(extract(epoch FROM now() - w.lastseen)))::integer,
           'online', w.lastseen > now() - interval '90 seconds')
         ORDER BY w.lastseen DESC), '[]'::jsonb)
    INTO v_workers
  FROM public.aiworker w;

  RETURN jsonb_build_object(
    'online', EXISTS (SELECT 1 FROM public.aiworker w
                       WHERE w.lastseen > now() - interval '90 seconds'),
    'workers', v_workers,
    'queued',  (SELECT count(*) FROM public.aijob WHERE status = 'queued'),
    'running', (SELECT count(*) FROM public.aijob WHERE status = 'processing'),
    'failed_24h', (SELECT count(*) FROM public.aijob
                    WHERE status = 'failed' AND finishedat > now() - interval '24 hours'));
END;
$$;


-- ---------------------------------------------------------------------
-- 6. Worker: save one analysis (the uploaded results.json) in the tables
--
-- p_result = the results.json AS UPLOADED by backend/upload_results.py
-- (picture paths already bucket paths, "mediaid" on every file).
-- One row per tracked object; a re-run of the same file UPDATES its rows
-- (same media + type + track id), so ids, suspect reviews and case links
-- survive. Old rows the new run no longer has are deleted unless a person
-- already worked on them (verified, suspect reviewed, corrected).
-- p_summary = the submission's AI summary text (optional).
-- ---------------------------------------------------------------------
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
  v_class    text;
BEGIN
  IF p_result IS NULL OR jsonb_typeof(p_result -> 'files') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'p_result must be a results.json object with a "files" list';
  END IF;

  SELECT * INTO v_cs FROM public.crimescene WHERE incidentid = p_incidentid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Incident % not found', p_incidentid;
  END IF;

  -- analysed again after it was combined into its case: take the old
  -- results out first (finish_job queues a fresh merge)
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

    IF v_file ? 'error' THEN                 -- this file could not be analysed
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

    -- people first: weapons point at the person holding them
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
        -- the rest of what the AI said (paths and fingerprints have their own columns)
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
      RETURNING detectionid INTO v_detid;
      v_keep := v_keep || v_detid;

      -- details; a value an investigator corrected (correctionlog) is kept
      IF NOT EXISTS (SELECT 1 FROM public.correctionlog c WHERE c.detectionid = v_detid) THEN
        IF v_kind = 'vehicle' THEN
          INSERT INTO public.vehicledetail (detectionid, vehicletype, make, colour,
                                            platedetected, licenceplatenumber, plateconfidence)
          VALUES (v_detid,
                  left(v_det ->> 'class_name', 50),
                  left(v_det ->> 'make', 100),
                  left(v_det ->> 'colour', 50),
                  public.normalize_plate(v_det ->> 'plate') IS NOT NULL,
                  left(public.normalize_plate(v_det ->> 'plate'), 20),
                  LEAST(GREATEST(round(public.ai_num(v_det -> 'plate_confidence'), 4), 0), 1))
          ON CONFLICT (detectionid) DO UPDATE
            SET vehicletype        = EXCLUDED.vehicletype,
                make               = EXCLUDED.make,
                colour             = EXCLUDED.colour,
                platedetected      = EXCLUDED.platedetected,
                licenceplatenumber = EXCLUDED.licenceplatenumber,
                plateconfidence    = EXCLUDED.plateconfidence;
        ELSIF v_kind = 'weapon' THEN
          v_class := lower(COALESCE(v_det ->> 'class_name', 'unknown'));
          INSERT INTO public.weapondetail (detectionid, weapontype, heldbydetectionid)
          VALUES (v_detid,
                  CASE WHEN v_class IN ('handgun', 'long_gun', 'rifle', 'shotgun', 'knife',
                                        'machete', 'explosive', 'other', 'unknown')
                       THEN v_class ELSE 'other' END,
                  (SELECT p.detectionid FROM public.detection p
                    WHERE p.mediaid = v_mediaid AND p.detectiontype = 'person'
                      AND p.trackid = public.ai_num(v_det -> 'held_by_person')))
          ON CONFLICT (detectionid) DO UPDATE
            SET weapontype        = EXCLUDED.weapontype,
                heldbydetectionid = EXCLUDED.heldbydetectionid;
        END IF;
      END IF;
    END LOOP;

    -- rows of an earlier run the new run doesn't have, nobody worked on
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

  -- where: the files' own GPS beats the phone's
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


-- ---------------------------------------------------------------------
-- 7. Worker: load and save a case's people / vehicles / weapons
--
-- ai_load_case / ai_load_submission return exactly the dicts
-- ai/case_matcher.py works with (case_matcher.new_case / submission_record),
-- with the DETECTION ID as each member's "key" and the media id as its
-- "file_index". So the worker does:
--
--   case = rpc('ai_load_case', {'p_caseid': 7})
--   sub  = rpc('ai_load_submission', {'p_incidentid': 42})
--   case_matcher.merge_submission(case, sub)
--   rpc('ai_save_case', {'p_caseid': 7, 'p_case': case})
-- ---------------------------------------------------------------------

-- One detection as a case_matcher member
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
        'upper_clothing',            d.attributes -> 'upper_clothing',
        'upper_clothing_confidence', d.attributes -> 'upper_clothing_confidence',
        'lower_clothing',            d.attributes -> 'lower_clothing',
        'lower_clothing_confidence', d.attributes -> 'lower_clothing_confidence',
        'face_visible',              d.attributes -> 'face_visible',
        'face_size_px',              d.attributes -> 'face_size_px',
        'clothing_views',            d.attributes -> 'clothing_views')
      -- vehicles: an investigator's correction in vehicledetail wins
      WHEN 'vehicle' THEN jsonb_build_object(
        'class_name',        COALESCE(to_jsonb(vd.vehicletype), d.attributes -> 'class_name'),
        'make',              COALESCE(to_jsonb(vd.make), d.attributes -> 'make'),
        'make_confidence',   d.attributes -> 'make_confidence',
        'make_views',        d.attributes -> 'make_views',
        'colour',            COALESCE(to_jsonb(vd.colour), d.attributes -> 'colour'),
        'colour_confidence', d.attributes -> 'colour_confidence',
        'plate',             to_jsonb(public.normalize_plate(
                               COALESCE(vd.licenceplatenumber, d.attributes ->> 'plate'))),
        'plate_confidence',  COALESCE(to_jsonb(vd.plateconfidence), d.attributes -> 'plate_confidence'),
        'plate_reads',       d.attributes -> 'plate_reads',
        'frames_seen',       to_jsonb(d.framesseen))
      ELSE jsonb_build_object(
        'kind',              d.attributes -> 'class_name',
        'weapon_confidence', d.attributes -> 'weapon_confidence',
        'frames_seen',       to_jsonb(d.framesseen))
    END)
  FROM public.detection d
  JOIN public.media m ON m.mediaid = d.mediaid
  LEFT JOIN public.vehicledetail vd ON vd.detectionid = d.detectionid
  LEFT JOIN public.weapondetail  wd ON wd.detectionid = d.detectionid
  WHERE d.detectionid = p_detectionid
$$;

-- An incident as a case_matcher submission record (without its members)
CREATE OR REPLACE FUNCTION public.ai_submission_info(p_incidentid integer)
  RETURNS jsonb
  LANGUAGE sql STABLE
  SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'submission',   cs.incidentid,
    'results_path', (SELECT max(m.airesultpath) FROM public.media m WHERE m.incidentid = cs.incidentid),
    'location',     CASE WHEN cs.latitude IS NOT NULL THEN
                      jsonb_build_object('latitude', cs.latitude, 'longitude', cs.longitude,
                                         'source', COALESCE(cs.gpssource, 'phone')) END,
    'capture_time', (SELECT min(m.capturetimestamp) FROM public.media m WHERE m.incidentid = cs.incidentid),
    'processed_at', (SELECT max(m.airesultat) FROM public.media m WHERE m.incidentid = cs.incidentid),
    'files',        COALESCE((
       SELECT jsonb_agg(jsonb_build_object(
                'file_index', m.mediaid,
                'file_name', regexp_replace(m.storagepath, '^.*/', ''),
                'source_type', m.mediatype,
                'capture_time', m.capturetimestamp) ORDER BY m.mediaid)
       FROM public.media m
       WHERE m.incidentid = cs.incidentid AND m.processingstatus <> 'failed'), '[]'::jsonb))
  FROM public.crimescene cs
  WHERE cs.incidentid = p_incidentid
$$;

-- case_matcher.submission_record() for incident p_incidentid, from the tables
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
    WHERE m.incidentid = p_incidentid AND m.processingstatus <> 'failed'), '[]'::jsonb));
END;
$$;

-- case_matcher's case dict for case p_caseid, from the tables
CREATE OR REPLACE FUNCTION public.ai_load_case(p_caseid integer)
  RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_case public.cases;
BEGIN
  SELECT * INTO v_case FROM public.cases WHERE caseid = p_caseid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Case % not found', p_caseid;
  END IF;

  RETURN jsonb_build_object(
    'case_id',    v_case.caseid,
    'title',      v_case.title,
    'status',     v_case.status,
    'created_at', v_case.datecreated,
    'updated_at', v_case.aisummaryat,
    'summary',    v_case.aisummary,
    -- submissions already combined into the case
    'submissions', COALESCE((
       SELECT jsonb_agg(public.ai_submission_info(cs.incidentid) ORDER BY cs.incidentid)
       FROM public.crimescene cs
       WHERE cs.caseid = p_caseid AND cs.reviewstatus = 'accepted' AND cs.aimerged), '[]'::jsonb),
    'entities', COALESCE((
       SELECT jsonb_agg(jsonb_build_object(
                'entity_id', public.ai_entity_key(e.kind, e.number),
                'kind',      e.kind,
                'label',     public.ai_entity_label(e.kind, e.number),
                'attributes', e.attributes,
                'cover',     e.coverpath,
                'updated',   e.updates,
                'held_by_entity', (SELECT public.ai_entity_key(h.kind, h.number)
                                     FROM public.caseentity h WHERE h.entityid = e.heldbyentityid),
                'members', COALESCE((
                   SELECT jsonb_agg(public.ai_member(d.detectionid)
                                    ORDER BY m.incidentid, m.mediaid, d.firstseen, d.detectionid)
                   FROM public.detection d
                   JOIN public.media m ON m.mediaid = d.mediaid
                   WHERE d.caseentityid = e.entityid), '[]'::jsonb))
              ORDER BY CASE e.kind WHEN 'person' THEN 1 WHEN 'vehicle' THEN 2 ELSE 3 END, e.number)
       FROM public.caseentity e WHERE e.caseid = p_caseid), '[]'::jsonb),
    'rejected', COALESCE((
       SELECT jsonb_agg(jsonb_build_array(r.detectionid::text, public.ai_entity_key(e.kind, e.number))
                        ORDER BY r.rejectedat, r.detectionid)
       FROM public.entitymatchrejection r
       JOIN public.caseentity e ON e.entityid = r.entityid
       WHERE e.caseid = p_caseid), '[]'::jsonb),
    -- highest number used per kind, so new entities continue from there
    'counters', COALESCE((
       SELECT jsonb_object_agg(e.kind, e.n)
       FROM (SELECT kind, max(number) AS n FROM public.caseentity
              WHERE caseid = p_caseid GROUP BY kind) e), '{}'::jsonb));
END;
$$;

-- Store the case dict back (after merge_submission / re-vote / rematch).
-- Replaces the case's people / vehicles / weapons with the ones in p_case,
-- but the database has the last word on human decisions and on what is
-- in the case NOW (the admin may have acted while the worker was busy):
--   * only detections of submissions accepted in this case are linked
--   * an admin's "Yes" (confirmed) is never changed, and only an admin can
--     confirm (a 'confirmed' the database doesn't know becomes 'suggested')
--   * an admin's "No" (entitymatchrejection) is never linked again
-- Entities left without settled pictures are dropped.
CREATE OR REPLACE FUNCTION public.ai_save_case(p_caseid integer, p_case jsonb)
  RETURNS jsonb
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_e       jsonb;
  v_kind    text;
  v_number  integer;
  v_id      integer;
  v_ids     jsonb := '{}'::jsonb;       -- 'p2' -> entityid
  v_cover   text;
  v_skipped integer;
  v_summary text := NULLIF(trim(COALESCE(p_case ->> 'summary', '')), '');
BEGIN
  PERFORM 1 FROM public.cases WHERE caseid = p_caseid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Case % not found', p_caseid;
  END IF;
  IF jsonb_typeof(p_case -> 'entities') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'p_case must be a case_matcher case with an "entities" list';
  END IF;

  -- 1. entities (insert new ones, update existing ones)
  FOR v_e IN SELECT e FROM jsonb_array_elements(p_case -> 'entities') e LOOP
    v_kind := v_e ->> 'kind';
    v_number := substring(v_e ->> 'entity_id' FROM '^[pvw]([0-9]{1,6})$')::integer;
    IF v_kind IS NULL OR v_kind NOT IN ('person', 'vehicle', 'weapon') OR v_number IS NULL
       OR left(v_e ->> 'entity_id', 1) <> left(v_kind, 1) THEN
      RAISE EXCEPTION 'Bad entity % (kind %): entity_id must be p<n>, v<n> or w<n>',
        v_e ->> 'entity_id', v_kind;
    END IF;
    IF v_ids ? (v_e ->> 'entity_id') THEN
      RAISE EXCEPTION 'Entity % is in the case twice', v_e ->> 'entity_id';
    END IF;

    -- the cover must be a picture of one of this case's submissions
    v_cover := v_e ->> 'cover';
    IF v_cover IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM public.crimescene cs
         WHERE cs.caseid = p_caseid
           AND v_cover LIKE cs.incidentid || '/ai/%' AND v_cover NOT LIKE '%..%') THEN
      v_cover := NULL;
    END IF;

    INSERT INTO public.caseentity AS ce (caseid, kind, number, attributes, coverpath, updates, updatedat)
    VALUES (p_caseid, v_kind, v_number,
            CASE WHEN jsonb_typeof(v_e -> 'attributes') = 'object' THEN v_e -> 'attributes'
                 ELSE '{}'::jsonb END,
            v_cover,
            -- keep the last 20 changes
            COALESCE((SELECT jsonb_agg(u ORDER BY n)
                        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(v_e -> 'updated') = 'array'
                                                       THEN v_e -> 'updated' ELSE '[]'::jsonb END)
                             WITH ORDINALITY AS x(u, n)
                       WHERE n > jsonb_array_length(CASE WHEN jsonb_typeof(v_e -> 'updated') = 'array'
                                                         THEN v_e -> 'updated' ELSE '[]'::jsonb END) - 20),
                     '[]'::jsonb),
            now())
    ON CONFLICT (caseid, kind, number) DO UPDATE
      SET attributes = EXCLUDED.attributes, coverpath = EXCLUDED.coverpath,
          updates = EXCLUDED.updates, updatedat = now()
    RETURNING entityid INTO v_id;
    v_ids := v_ids || jsonb_build_object(v_e ->> 'entity_id', v_id);
  END LOOP;

  -- weapons: who holds them
  UPDATE public.caseentity ce
     SET heldbyentityid = CASE WHEN ce.kind = 'weapon'
                               THEN (v_ids ->> (e ->> 'held_by_entity'))::integer END
    FROM jsonb_array_elements(p_case -> 'entities') e
   WHERE ce.entityid = (v_ids ->> (e ->> 'entity_id'))::integer
     AND ce.heldbyentityid IS DISTINCT FROM
         CASE WHEN ce.kind = 'weapon' THEN (v_ids ->> (e ->> 'held_by_entity'))::integer END;

  -- 2. pictures -> entities
  WITH valid AS (            -- detections of the submissions accepted in this case
    SELECT d.detectionid, d.detectiontype, d.caseentityid, d.matchstatus
    FROM public.crimescene cs
    JOIN public.media m     ON m.incidentid = cs.incidentid
    JOIN public.detection d ON d.mediaid = m.mediaid
    WHERE cs.caseid = p_caseid AND cs.reviewstatus = 'accepted'
  ),
  wanted AS (                -- what the worker says, one entity per detection
    SELECT DISTINCT ON (x.detectionid)
           x.detectionid, x.entityid, x.status, x.score, x.reasons
    FROM (
      SELECT (mem ->> 'key')::integer AS detectionid,
             (v_ids ->> (e ->> 'entity_id'))::integer AS entityid,
             e ->> 'kind' AS kind,
             mem ->> 'status' AS status,
             public.ai_num(mem -> 'score') AS score,
             CASE WHEN jsonb_typeof(mem -> 'reasons') = 'array'
                  THEN ARRAY(SELECT jsonb_array_elements_text(mem -> 'reasons')) END AS reasons,
             en, mn
      FROM jsonb_array_elements(p_case -> 'entities') WITH ORDINALITY AS a(e, en),
           jsonb_array_elements(CASE WHEN jsonb_typeof(e -> 'members') = 'array'
                                     THEN e -> 'members' ELSE '[]'::jsonb END)
             WITH ORDINALITY AS b(mem, mn)
      WHERE (mem ->> 'key') ~ '^[0-9]{1,9}$'
        AND mem ->> 'status' IN ('first', 'auto', 'confirmed', 'suggested')
    ) x
    JOIN valid v ON v.detectionid = x.detectionid AND v.detectiontype = x.kind
    WHERE NOT EXISTS (SELECT 1 FROM public.entitymatchrejection r
                       WHERE r.detectionid = x.detectionid AND r.entityid = x.entityid)
    ORDER BY x.detectionid, x.en, x.mn
  ),
  target AS (
    SELECT v.detectionid,
           CASE WHEN v.matchstatus = 'confirmed' THEN v.caseentityid ELSE w.entityid END AS entityid,
           CASE WHEN v.matchstatus = 'confirmed' THEN 'confirmed'
                WHEN w.status = 'confirmed' THEN 'suggested'     -- only admins confirm
                ELSE w.status END AS status,
           w.score, w.reasons, v.matchstatus AS oldstatus
    FROM valid v
    LEFT JOIN wanted w ON w.detectionid = v.detectionid
  )
  UPDATE public.detection d
     SET caseentityid = t.entityid,
         matchstatus  = CASE WHEN t.entityid IS NULL THEN NULL ELSE t.status END,
         matchscore   = CASE WHEN t.oldstatus = 'confirmed' THEN d.matchscore
                             WHEN t.entityid IS NULL THEN NULL ELSE round(t.score, 3) END,
         matchreasons = CASE WHEN t.oldstatus = 'confirmed' THEN d.matchreasons
                             WHEN t.entityid IS NULL THEN NULL ELSE t.reasons END
    FROM target t
   WHERE d.detectionid = t.detectionid
     AND (d.caseentityid IS DISTINCT FROM t.entityid
          OR d.matchstatus IS DISTINCT FROM CASE WHEN t.entityid IS NULL THEN NULL ELSE t.status END
          OR (t.oldstatus IS DISTINCT FROM 'confirmed'
              AND (d.matchscore IS DISTINCT FROM round(t.score, 3)
                   OR d.matchreasons IS DISTINCT FROM t.reasons)));

  -- members the worker sent that the database did not take
  SELECT count(*) INTO v_skipped
  FROM jsonb_array_elements(p_case -> 'entities') e,
       jsonb_array_elements(CASE WHEN jsonb_typeof(e -> 'members') = 'array'
                                 THEN e -> 'members' ELSE '[]'::jsonb END) mem
  WHERE NOT EXISTS (
    SELECT 1 FROM public.detection d
    WHERE (mem ->> 'key') ~ '^[0-9]{1,9}$'
      AND d.detectionid = (mem ->> 'key')::integer
      AND d.caseentityid = (v_ids ->> (e ->> 'entity_id'))::integer);

  -- 3. tidy up, mark which submissions are combined
  PERFORM public.ai_drop_empty_entities(p_caseid);

  UPDATE public.crimescene cs
     SET aimerged = (cs.incidentid IN (
           SELECT (s ->> 'submission')::integer
           FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_case -> 'submissions') = 'array'
                                          THEN p_case -> 'submissions' ELSE '[]'::jsonb END) s
           WHERE (s ->> 'submission') ~ '^[0-9]{1,9}$'))
   WHERE cs.caseid = p_caseid AND cs.reviewstatus = 'accepted';

  -- 4. the case summary (outdated straight away if more work is waiting)
  UPDATE public.cases
     SET aisummary = left(v_summary, 600),
         aisummaryat = now(),
         aisummarystatus = CASE
           WHEN v_summary IS NULL THEN 'none'
           WHEN EXISTS (SELECT 1 FROM public.aijob j
                         WHERE j.caseid = p_caseid AND j.status = 'queued') THEN 'outdated'
           ELSE 'ready' END
   WHERE caseid = p_caseid;

  RETURN jsonb_build_object(
    'entities',  (SELECT count(*) FROM public.caseentity WHERE caseid = p_caseid),
    'linked',    (SELECT count(*) FROM public.detection d JOIN public.caseentity e
                    ON e.entityid = d.caseentityid
                   WHERE e.caseid = p_caseid AND d.matchstatus <> 'suggested'),
    'questions', (SELECT count(*) FROM public.detection d JOIN public.caseentity e
                    ON e.entityid = d.caseentityid
                   WHERE e.caseid = p_caseid AND d.matchstatus = 'suggested'),
    'skipped',   v_skipped);
END;
$$;


-- ---------------------------------------------------------------------
-- 8. Triggers
-- ---------------------------------------------------------------------

-- 8a. A submission joins / leaves a case -> queue / undo the merge.
--     "In the case" = caseid set AND reviewstatus 'accepted' (duplicates
--     sit in the case too, but their footage is not combined twice).
--       joins  (accept, add to case, create case from it) -> 'merge'
--              (unless an analysis is still waiting: finish_job queues
--              the merge when it is done)
--       leaves (remove, reject, move, mark duplicate)    -> unlinked now
--       moves X -> Y                                      -> both
CREATE OR REPLACE FUNCTION public.queue_case_ai_work()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_old integer := CASE WHEN TG_OP = 'UPDATE' AND OLD.reviewstatus = 'accepted' THEN OLD.caseid END;
  v_new integer := CASE WHEN NEW.reviewstatus = 'accepted' THEN NEW.caseid END;
BEGIN
  IF v_old IS NOT DISTINCT FROM v_new THEN
    RETURN NULL;
  END IF;

  IF v_old IS NOT NULL THEN
    PERFORM public.ai_unmerge_incident(NEW.incidentid, v_old);
  END IF;

  IF v_new IS NOT NULL THEN
    UPDATE public.cases SET aisummarystatus = 'outdated'
     WHERE caseid = v_new AND aisummarystatus <> 'none';
    IF NOT EXISTS (SELECT 1 FROM public.aijob j
                    WHERE j.kind = 'analyse' AND j.incidentid = NEW.incidentid
                      AND j.status IN ('queued', 'processing')) THEN
      PERFORM public.queue_ai_job('merge', NEW.incidentid, v_new);
    END IF;
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER queue_case_ai_work
  AFTER INSERT OR UPDATE OF caseid, reviewstatus ON public.crimescene
  FOR EACH ROW EXECUTE FUNCTION public.queue_case_ai_work();

-- 8b. Deleting a case: same as before (incidents go back to pending), plus
--     a flag so the unmerge above leaves the disappearing case row alone
--     (Postgres refuses to change a row in the middle of deleting it).
CREATE OR REPLACE FUNCTION public.release_case_incidents()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  PERFORM set_config('argus.deleting_case', OLD.caseid::text, true);
  UPDATE public.crimescene
     SET caseid = NULL, reviewstatus = 'pending',
         reviewedby = NULL, reviewedat = NULL, reviewnote = NULL
   WHERE caseid = OLD.caseid AND reviewstatus = 'accepted';
  UPDATE public.crimescene
     SET caseid = NULL
   WHERE caseid = OLD.caseid;   -- duplicates stay duplicates
  PERFORM set_config('argus.deleting_case', '', true);
  RETURN OLD;
END;
$$;

-- 8c. A detection that leaves its entity (unlinked, or its entity was
--     deleted) loses its match status / score / reasons too
CREATE OR REPLACE FUNCTION public.detection_clear_match()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF NEW.caseentityid IS NULL THEN
    NEW.matchstatus  := NULL;
    NEW.matchscore   := NULL;
    NEW.matchreasons := NULL;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER detection_clear_match
  BEFORE UPDATE OF caseentityid ON public.detection
  FOR EACH ROW EXECUTE FUNCTION public.detection_clear_match();

-- 8d. App users can't write AI output. Corrections keep going through
--     correctionlog / vehicledetail as before.
CREATE OR REPLACE FUNCTION public.protect_detection_ai()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
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

CREATE TRIGGER protect_detection_ai
  BEFORE INSERT OR UPDATE ON public.detection
  FOR EACH ROW EXECUTE FUNCTION public.protect_detection_ai();

-- media: + latitude / longitude (per-file GPS comes from the AI worker)
CREATE OR REPLACE FUNCTION public.protect_media_ai()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') AND (
       (TG_OP = 'INSERT' AND (NEW.aidescription IS NOT NULL
                              OR NEW.aidescribedat IS NOT NULL
                              OR NEW.airesultpath  IS NOT NULL
                              OR NEW.airesultat    IS NOT NULL
                              OR NEW.latitude      IS NOT NULL
                              OR NEW.longitude     IS NOT NULL))
    OR (TG_OP = 'UPDATE' AND (NEW.aidescription IS DISTINCT FROM OLD.aidescription
                              OR NEW.aidescribedat IS DISTINCT FROM OLD.aidescribedat
                              OR NEW.airesultpath  IS DISTINCT FROM OLD.airesultpath
                              OR NEW.airesultat    IS DISTINCT FROM OLD.airesultat
                              OR NEW.latitude      IS DISTINCT FROM OLD.latitude
                              OR NEW.longitude     IS DISTINCT FROM OLD.longitude)))
  THEN
    RAISE EXCEPTION 'AI fields are written by the analysis pipeline only';
  END IF;
  RETURN NEW;
END;
$$;

-- crimescene: + aimerged; gpssource 'file' only from the AI worker (the
-- app may say 'phone' or 'typed')
CREATE OR REPLACE FUNCTION public.protect_crimescene_ai()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') AND (
       (TG_OP = 'INSERT' AND (NEW.aisummary IS NOT NULL
                              OR NEW.aisummarystatus <> 'none'
                              OR NEW.aisummaryat IS NOT NULL
                              OR NEW.aimerged
                              OR NEW.gpssource = 'file'))
    OR (TG_OP = 'UPDATE' AND (NEW.aisummary       IS DISTINCT FROM OLD.aisummary
                              OR NEW.aisummarystatus IS DISTINCT FROM OLD.aisummarystatus
                              OR NEW.aisummaryat     IS DISTINCT FROM OLD.aisummaryat
                              OR NEW.aimerged        IS DISTINCT FROM OLD.aimerged
                              OR (NEW.gpssource IS DISTINCT FROM OLD.gpssource
                                  AND 'file' IN (NEW.gpssource, OLD.gpssource)))))
  THEN
    RAISE EXCEPTION 'AI fields are written by the analysis pipeline only';
  END IF;
  RETURN NEW;
END;
$$;

-- cases: the AI summary is written by the worker only
CREATE OR REPLACE FUNCTION public.protect_cases_ai()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
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
$$;

CREATE TRIGGER protect_cases_ai
  BEFORE INSERT OR UPDATE ON public.cases
  FOR EACH ROW EXECUTE FUNCTION public.protect_cases_ai();


-- ---------------------------------------------------------------------
-- 9. get_case_evidence - everything the case screen's AI section shows.
--    Exactly the shape of ai/case_matcher.py case_view() (the Flutter
--    model CaseEvidence.fromMap reads it). member_key = the detection id
--    as text; crop paths are bucket paths (the app makes signed URLs).
--    Admins, and investigators assigned to the case. NULL if no such case.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_case_evidence(p_caseid integer)
  RETURNS jsonb
  LANGUAGE plpgsql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_case   public.cases;
  v_groups jsonb;
BEGIN
  IF public.current_user_role() IS DISTINCT FROM 'admin'
     AND NOT public.is_assigned_to_case(p_caseid) THEN
    RAISE EXCEPTION 'Only admins and investigators assigned to this case can see its evidence'
      USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_case FROM public.cases WHERE caseid = p_caseid;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  WITH member AS (
    SELECT d.detectionid, d.caseentityid, d.matchstatus, d.matchscore, d.matchreasons,
           d.crops, d.trackid, d.firstseen, m.incidentid, m.mediaid, m.capturetimestamp,
           regexp_replace(m.storagepath, '^.*/', '') AS file_name,
           d.matchstatus IN ('first', 'auto', 'confirmed') AS settled
    FROM public.caseentity e
    JOIN public.detection d ON d.caseentityid = e.entityid
    JOIN public.media m     ON m.mediaid = d.mediaid
    WHERE e.caseid = p_caseid
  ),
  crop AS (                           -- case_matcher case_view() crops_of()
    SELECT mb.detectionid, mb.caseentityid, mb.settled,
           jsonb_build_object(
             'path', c ->> 'path', 'type', c ->> 'type', 'submission', mb.incidentid,
             'file_name', mb.file_name, 'track_id', mb.trackid,
             'seen_seconds', COALESCE(mb.firstseen, 0), 'capture_time', mb.capturetimestamp) AS j,
           row_number() OVER (ORDER BY mb.incidentid, mb.mediaid, mb.firstseen,
                                       mb.detectionid, x.n) AS n
    FROM member mb,
         jsonb_array_elements(mb.crops) WITH ORDINALITY AS x(c, n)
  ),
  entity AS (
    SELECT e.kind, e.number,
           jsonb_build_object(
             'entity_id',   public.ai_entity_key(e.kind, e.number),
             'kind',        e.kind,
             'label',       public.ai_entity_label(e.kind, e.number),
             'description', public.ai_entity_description(e.kind, e.attributes),
             'attributes',  COALESCE((SELECT jsonb_object_agg(k, v)
                                       FROM jsonb_each(e.attributes) AS a(k, v)
                                      WHERE k NOT LIKE '%\_top3'), '{}'::jsonb),
             'cover',       e.coverpath,
             'submission_count', (SELECT count(DISTINCT mb.incidentid) FROM member mb
                                   WHERE mb.caseentityid = e.entityid AND mb.settled),
             'crops',       COALESCE((SELECT jsonb_agg(c.j ORDER BY c.n) FROM crop c
                                       WHERE c.caseentityid = e.entityid AND c.settled), '[]'::jsonb),
             'questions',   COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                         'member_key', mb.detectionid::text,
                         'submission', mb.incidentid,
                         'file_name',  mb.file_name,
                         'score',      mb.matchscore,
                         'reasons',    COALESCE(to_jsonb(mb.matchreasons), '[]'::jsonb),
                         'crops',      COALESCE((SELECT jsonb_agg(c.j ORDER BY c.n) FROM crop c
                                                  WHERE c.detectionid = mb.detectionid), '[]'::jsonb))
                       ORDER BY mb.incidentid, mb.mediaid, mb.firstseen, mb.detectionid)
                FROM member mb
                WHERE mb.caseentityid = e.entityid AND NOT mb.settled), '[]'::jsonb),
             'updated',     COALESCE((SELECT jsonb_agg(u ORDER BY n)
                                       FROM jsonb_array_elements(e.updates) WITH ORDINALITY AS x(u, n)
                                      WHERE n > jsonb_array_length(e.updates) - 5), '[]'::jsonb)
           ) AS j
    FROM public.caseentity e
    WHERE e.caseid = p_caseid
  )
  SELECT jsonb_build_object(
           'people',   COALESCE(jsonb_agg(j ORDER BY number) FILTER (WHERE kind = 'person'),  '[]'::jsonb),
           'vehicles', COALESCE(jsonb_agg(j ORDER BY number) FILTER (WHERE kind = 'vehicle'), '[]'::jsonb),
           'weapons',  COALESCE(jsonb_agg(j ORDER BY number) FILTER (WHERE kind = 'weapon'),  '[]'::jsonb))
    INTO v_groups
  FROM entity;

  RETURN jsonb_build_object(
    'case_id',    v_case.caseid,
    'title',      v_case.title,
    'ai_summary', COALESCE(v_case.aisummary, ''),
    'submissions', COALESCE((
       SELECT jsonb_agg(jsonb_build_object(
                'submission',   s.info -> 'submission',
                'capture_time', s.info -> 'capture_time',
                'location',     s.info -> 'location',
                'file_count',   jsonb_array_length(s.info -> 'files'))
              ORDER BY s.incidentid)
       FROM (SELECT cs.incidentid, public.ai_submission_info(cs.incidentid) AS info
               FROM public.crimescene cs
              WHERE cs.caseid = p_caseid AND cs.reviewstatus = 'accepted' AND cs.aimerged) s),
       '[]'::jsonb),
    'counts', jsonb_build_object(
       'people',   jsonb_array_length(v_groups -> 'people'),
       'vehicles', jsonb_array_length(v_groups -> 'vehicles'),
       'weapons',  jsonb_array_length(v_groups -> 'weapons')),
    'open_questions', (SELECT count(*) FROM public.caseentity e
                         JOIN public.detection d ON d.caseentityid = e.entityid
                        WHERE e.caseid = p_caseid AND d.matchstatus = 'suggested'),
    'people',   v_groups -> 'people',
    'vehicles', v_groups -> 'vehicles',
    'weapons',  v_groups -> 'weapons');
END;
$$;


-- ---------------------------------------------------------------------
-- 10. answer_entity_match - the admin answers "Is this Person 2?"
--     Yes -> confirmed; the worker re-votes Person 2's details ('summary')
--     No  -> never asked again; the worker finds another match or makes a
--            new person ('rematch')
-- ---------------------------------------------------------------------
ALTER TABLE public.caseevent DROP CONSTRAINT caseevent_eventtype_check;
ALTER TABLE public.caseevent ADD CONSTRAINT caseevent_eventtype_check
  CHECK (eventtype IN (
    'submitted', 'added_to_case', 'removed_from_case', 'rejected', 'duplicate', 'reopened',
    'case_created', 'case_edited', 'status_changed', 'case_deleted',
    'assigned', 'unassigned', 'lead_changed',
    'detection_verified', 'detection_unverified',
    'suspect_confirmed', 'suspect_dismissed', 'suspect_review_undone', 'suspect_edited',
    'ai_match_confirmed', 'ai_match_rejected'));

CREATE OR REPLACE FUNCTION public.answer_entity_match(p_detectionid integer, p_yes boolean)
  RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_det    public.detection;
  v_entity public.caseentity;
  v_status text;
  v_incidentid integer;
BEGIN
  PERFORM public.require_admin();
  IF p_yes IS NULL THEN
    RAISE EXCEPTION 'Answer yes or no';
  END IF;

  SELECT * INTO v_det FROM public.detection WHERE detectionid = p_detectionid FOR UPDATE;
  IF NOT FOUND OR v_det.matchstatus IS DISTINCT FROM 'suggested' THEN
    RAISE EXCEPTION 'There is no open question for detection % (it may already be answered)', p_detectionid;
  END IF;
  SELECT * INTO v_entity FROM public.caseentity WHERE entityid = v_det.caseentityid;
  SELECT status INTO v_status FROM public.cases WHERE caseid = v_entity.caseid;
  IF v_status = 'closed' THEN
    RAISE EXCEPTION 'Case % is closed; reopen it first', v_entity.caseid;
  END IF;
  SELECT incidentid INTO v_incidentid FROM public.media WHERE mediaid = v_det.mediaid;

  IF p_yes THEN
    UPDATE public.detection SET matchstatus = 'confirmed' WHERE detectionid = p_detectionid;
    PERFORM public.queue_ai_job('summary', NULL, v_entity.caseid);
  ELSE
    INSERT INTO public.entitymatchrejection (detectionid, entityid, rejectedby)
    VALUES (p_detectionid, v_entity.entityid, public.current_user_id())
    ON CONFLICT DO NOTHING;
    UPDATE public.detection SET caseentityid = NULL WHERE detectionid = p_detectionid;
    PERFORM public.queue_ai_job('rematch', NULL, v_entity.caseid, p_detectionid);
  END IF;

  UPDATE public.cases SET aisummarystatus = 'outdated'
   WHERE caseid = v_entity.caseid AND aisummarystatus <> 'none';
  PERFORM public.log_case_event(
    CASE WHEN p_yes THEN 'ai_match_confirmed' ELSE 'ai_match_rejected' END,
    v_entity.caseid, v_incidentid,
    CASE WHEN p_yes THEN 'is ' ELSE 'is not ' END
      || public.ai_entity_label(v_entity.kind, v_entity.number));
END;
$$;


-- ---------------------------------------------------------------------
-- 11. list_cases (and getCase) also return the case's AI summary
--     Same as 20261006090000 plus aisummary / aisummarystatus /
--     aisummaryat at the end. The return type changes, so DROP + CREATE.
-- ---------------------------------------------------------------------
DROP FUNCTION public.list_cases(text, text, integer, integer, timestamptz, integer);

CREATE FUNCTION public.list_cases(
  p_search     text        DEFAULT NULL,
  p_status     text        DEFAULT NULL,
  p_limit      integer     DEFAULT 20,
  p_caseid     integer     DEFAULT NULL,
  p_after_time timestamptz DEFAULT NULL,
  p_after_id   integer     DEFAULT NULL)
  RETURNS TABLE (
    caseid            integer,
    title             varchar,
    description       text,
    status            varchar,
    datecreated       timestamptz,
    dateclosed        timestamptz,
    createdbyname     text,
    incidentcount     integer,
    investigators     jsonb,
    lastactivity      timestamptz,
    mediacount        integer,
    plates            text[],
    preview           jsonb,
    possiblesuspects  integer,
    confirmedsuspects integer,
    aisummary         text,
    aisummarystatus   varchar,
    aisummaryat       timestamptz)
  LANGUAGE sql STABLE
  SET search_path = ''
AS $_$
  WITH t AS (
    SELECT raw,
           replace(replace(replace(raw, '\', '\\'), '%', '\%'), '_', '\_') AS term,
           CASE WHEN raw ~* '^(case)?[\s#-]*[0-9]{1,9}$'
                THEN substring(raw FROM '[0-9]+')::integer END AS num
    FROM (SELECT NULLIF(trim(COALESCE(p_search, '')), '') AS raw) q
  ),
  base AS (
    SELECT c.*,
           GREATEST(c.datecreated,
                    (SELECT max(cs.reviewedat) FROM public.crimescene cs
                      WHERE cs.caseid = c.caseid),
                    (SELECT max(e.occurredat) FROM public.caseevent e
                      WHERE e.caseid = c.caseid)) AS lastactivity
    FROM public.cases c CROSS JOIN t
    WHERE (t.raw IS NULL OR c.caseid = t.num OR c.title ILIKE '%' || t.term || '%')
      AND (NULLIF(p_status, '') IS NULL
           OR (p_status = 'active' AND c.status IN ('open', 'under_review'))
           OR c.status = p_status)
      AND (p_caseid IS NULL OR c.caseid = p_caseid)
  ),
  page AS (
    SELECT * FROM base b
    WHERE p_after_time IS NULL
       OR (b.lastactivity, b.caseid) < (p_after_time, COALESCE(p_after_id, 2147483647))
    ORDER BY b.lastactivity DESC, b.caseid DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
  )
  SELECT b.caseid, b.title, b.description, b.status, b.datecreated, b.dateclosed,
         NULLIF(trim(u.firstname || ' ' || u.surname), ''),
         (SELECT count(*)::integer FROM public.crimescene cs WHERE cs.caseid = b.caseid),
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'assignmentid', ca.assignmentid,
                    'userid', iu.userid,
                    'name', concat_ws(' ', i.rank, iu.firstname, iu.surname),
                    'badgenumber', i.badgenumber,
                    'islead', ca.islead)
                  ORDER BY ca.islead DESC, ca.dateassigned)
           FROM public.caseassignment ca
           JOIN public."User" iu ON iu.userid = ca.assignedto
           LEFT JOIN public.investigator i ON i.userid = ca.assignedto
           WHERE ca.caseid = b.caseid AND ca.assignmentstatus = 'active'
         ), '[]'::jsonb),
         b.lastactivity,
         (SELECT count(*)::integer FROM public.media m
            JOIN public.crimescene cs ON cs.incidentid = m.incidentid
           WHERE cs.caseid = b.caseid),
         ARRAY(SELECT DISTINCT public.normalize_plate(v.licenceplatenumber)
                 FROM public.crimescene cs
                 JOIN public.media m         ON m.incidentid = cs.incidentid
                 JOIN public.detection d     ON d.mediaid = m.mediaid
                 JOIN public.vehicledetail v ON v.detectionid = d.detectionid
                WHERE cs.caseid = b.caseid
                  AND public.normalize_plate(v.licenceplatenumber) IS NOT NULL
                ORDER BY 1
                LIMIT 3),
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'incidentid', x.incidentid,
                    'location', x.location,
                    'datereported', x.datereported,
                    'reviewstatus', x.reviewstatus,
                    'description', x.description,
                    'aisummary', x.aisummary)
                  ORDER BY x.datereported DESC, x.incidentid DESC)
           FROM (SELECT cs.incidentid, cs.location, cs.datereported, cs.reviewstatus,
                        cs.description, cs.aisummary
                   FROM public.crimescene cs
                  WHERE cs.caseid = b.caseid
                  ORDER BY cs.datereported DESC, cs.incidentid DESC
                  LIMIT 3) x
         ), '[]'::jsonb),
         COALESCE(sus.possible, 0), COALESCE(sus.confirmed, 0),
         b.aisummary, b.aisummarystatus, b.aisummaryat
  FROM page b
  LEFT JOIN public."User" u ON u.userid = b.createdby
  -- per clip, then the highest clip of any submission in the case
  LEFT JOIN LATERAL (
    SELECT max(per_clip.possible)::integer  AS possible,
           max(per_clip.confirmed)::integer AS confirmed
    FROM (SELECT count(*) FILTER (WHERE d.suspectstatus = 'possible')  AS possible,
                 count(*) FILTER (WHERE d.suspectstatus = 'confirmed') AS confirmed
            FROM public.crimescene cs
            JOIN public.media m     ON m.incidentid = cs.incidentid
            JOIN public.detection d ON d.mediaid = m.mediaid
           WHERE cs.caseid = b.caseid
             AND d.detectiontype = 'person'
           GROUP BY m.mediaid) per_clip
  ) sus ON true
  ORDER BY b.lastactivity DESC, b.caseid DESC
$_$;


-- ---------------------------------------------------------------------
-- 12. Privileges
--     Supabase gives new functions to anon + authenticated by default, so
--     every function says explicitly who may run it.
-- ---------------------------------------------------------------------

-- internal helpers and trigger functions: nobody calls them directly
REVOKE ALL ON FUNCTION
  public.ai_try_timestamptz(text),
  public.ai_num(jsonb),
  public.ai_vector(jsonb, integer),
  public.ai_crops(jsonb, integer),
  public.ai_entity_description(text, jsonb),
  public.ai_entity_key(text, integer),
  public.ai_entity_label(text, integer),
  public.queue_ai_job(text, integer, integer, integer),
  public.ai_job_failed(bigint, text),
  public.ai_drop_empty_entities(integer),
  public.ai_unmerge_incident(integer, integer),
  public.ai_member(integer),
  public.ai_submission_info(integer),
  public.queue_case_ai_work(),
  public.release_case_incidents(),
  public.detection_clear_match(),
  public.protect_detection_ai(),
  public.protect_media_ai(),
  public.protect_crimescene_ai(),
  public.protect_cases_ai()
FROM PUBLIC, anon, authenticated, service_role;

-- used by match_incidents (runs as the admin calling the suggestion functions)
REVOKE ALL ON FUNCTION
  public.appearance_similarity(extensions.vector, extensions.vector, extensions.vector, extensions.vector)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.appearance_similarity(extensions.vector, extensions.vector, extensions.vector, extensions.vector)
TO authenticated, service_role;

-- AI worker (service key) only
REVOKE ALL ON FUNCTION
  public.claim_next_job(text),
  public.finish_job(bigint, text),
  public.ai_worker_heartbeat(text, text, text),
  public.ai_save_analysis(integer, jsonb, text),
  public.ai_load_case(integer),
  public.ai_load_submission(integer),
  public.ai_save_case(integer, jsonb)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.claim_next_job(text),
  public.finish_job(bigint, text),
  public.ai_worker_heartbeat(text, text, text),
  public.ai_save_analysis(integer, jsonb, text),
  public.ai_load_case(integer),
  public.ai_load_submission(integer),
  public.ai_save_case(integer, jsonb)
TO service_role;

-- the app (each function checks who is calling)
REVOKE ALL ON FUNCTION
  public.submit_for_analysis(integer),
  public.get_case_evidence(integer),
  public.answer_entity_match(integer, boolean),
  public.ai_worker_status(),
  public.list_cases(text, text, integer, integer, timestamptz, integer)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.submit_for_analysis(integer),
  public.get_case_evidence(integer),
  public.answer_entity_match(integer, boolean),
  public.ai_worker_status(),
  public.list_cases(text, text, integer, integer, timestamptz, integer)
TO authenticated, service_role;
