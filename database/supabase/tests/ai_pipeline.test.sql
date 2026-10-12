-- =====================================================================
-- pgTAP tests for the AI pipeline migrations (20261012100000/100100/100200).
-- Run with the Supabase CLI from the database folder:
--
--     supabase start
--     supabase test db
--
-- Everything happens in one transaction that is rolled back.
-- The full end-to-end tests (worker + ai/case_matcher.py) are in
-- tests/test_ai_pipeline_db.py.
-- =====================================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(43);

-- ---------------------------------------------------------------------
-- Structure
-- ---------------------------------------------------------------------
SELECT has_table('public', 'aijob', 'job queue table exists');
SELECT has_table('public', 'aiworker', 'worker heartbeat table exists');
SELECT has_table('public', 'caseentity', 'case people / vehicles / weapons table exists');
SELECT has_table('public', 'entitymatchrejection', '"not this one" table exists');

SELECT col_type_is('public', 'detection', 'appearance', 'extensions', 'vector(512)', 'detection.appearance is vector(512)');
SELECT col_type_is('public', 'detection', 'colourhist', 'extensions', 'vector(96)', 'detection.colourhist is vector(96)');
SELECT has_column('public', 'detection', 'caseentityid', 'detection.caseentityid');
SELECT has_column('public', 'detection', 'crops', 'detection.crops');
SELECT has_column('public', 'cases', 'aisummary', 'cases.aisummary');
SELECT has_column('public', 'crimescene', 'gpssource', 'crimescene.gpssource');
SELECT has_column('public', 'weapondetail', 'heldbydetectionid', 'weapondetail.heldbydetectionid');

SELECT ok((SELECT bool_and(relrowsecurity) FROM pg_class
            WHERE oid IN ('public.aijob'::regclass, 'public.aiworker'::regclass,
                          'public.caseentity'::regclass, 'public.entitymatchrejection'::regclass)),
          'RLS is on for all new tables');
SELECT policies_are('public', 'caseentity', ARRAY['caseentity_select'], 'caseentity: read policy only');
SELECT policies_are('public', 'aijob', ARRAY[]::name[], 'aijob: no policies (service key only)');

-- ---------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------
SELECT function_privs_are('public', 'claim_next_job', ARRAY['text'], 'authenticated', ARRAY[]::text[],
                          'app users cannot claim jobs');
SELECT function_privs_are('public', 'claim_next_job', ARRAY['text'], 'service_role', ARRAY['EXECUTE'],
                          'the worker can claim jobs');
SELECT function_privs_are('public', 'ai_save_case', ARRAY['integer', 'jsonb'], 'authenticated', ARRAY[]::text[],
                          'app users cannot save case entities');
SELECT function_privs_are('public', 'ai_save_analysis', ARRAY['integer', 'jsonb', 'text'], 'anon', ARRAY[]::text[],
                          'anon cannot save analyses');
SELECT function_privs_are('public', 'submit_for_analysis', ARRAY['integer'], 'authenticated', ARRAY['EXECUTE'],
                          'app users can submit for analysis');
SELECT function_privs_are('public', 'submit_for_analysis', ARRAY['integer'], 'anon', ARRAY[]::text[],
                          'signed-out users cannot submit');
SELECT function_privs_are('public', 'get_case_evidence', ARRAY['integer'], 'authenticated', ARRAY['EXECUTE'],
                          'app users can call get_case_evidence (it checks who)');
SELECT function_privs_are('public', 'queue_ai_job', ARRAY['text', 'integer', 'integer', 'integer'],
                          'authenticated', ARRAY[]::text[], 'nobody queues jobs directly');
SELECT table_privs_are('public', 'aijob', 'authenticated', ARRAY[]::text[], 'app users have no access to aijob');
SELECT table_privs_are('public', 'caseentity', 'authenticated', ARRAY['SELECT'], 'app users can only read caseentity');

-- ---------------------------------------------------------------------
-- Test data: an admin, a citizen and an incident with two files
-- ---------------------------------------------------------------------
INSERT INTO auth.users (id, email, raw_user_meta_data, raw_app_meta_data) VALUES
  ('11111111-1111-1111-1111-111111111111', 'tap_admin@example.com',
   '{"username": "tap_admin", "firstname": "Tap", "surname": "Admin"}', '{"role": "admin"}'),
  ('22222222-2222-2222-2222-222222222222', 'tap_citizen@example.com',
   '{"username": "tap_citizen", "firstname": "Tap", "surname": "Citizen"}', '{"role": "citizen"}');

CREATE TEMP TABLE t AS
SELECT (SELECT userid FROM public."User" WHERE username = 'tap_admin')   AS admin,
       (SELECT userid FROM public."User" WHERE username = 'tap_citizen') AS citizen;
GRANT SELECT ON t TO authenticated, service_role;

INSERT INTO public.crimescene (location, datetime, reportedby, latitude, longitude)
SELECT 'Rivonia Rd', '2026-10-12 10:00+00', citizen, -26.1076, 28.0567 FROM t;
ALTER TABLE t ADD COLUMN inc integer;
UPDATE t SET inc = (SELECT max(incidentid) FROM public.crimescene);
INSERT INTO public.media (incidentid, uploadedby, mediatype, storagepath)
SELECT inc, citizen, 'video', inc || '/media/clip' || n || '.mp4' FROM t, generate_series(1, 2) n;

-- ---------------------------------------------------------------------
-- Queue: submit twice as the citizen -> one job
-- ---------------------------------------------------------------------
DO $$ BEGIN PERFORM set_config('request.jwt.claims', '{"sub": "22222222-2222-2222-2222-222222222222", "role": "authenticated"}', true); END $$;
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE submitted ON COMMIT DROP AS
SELECT public.submit_for_analysis((SELECT inc FROM t)) AS a,
       public.submit_for_analysis((SELECT inc FROM t)) AS b;
RESET ROLE;

SELECT is((SELECT a FROM submitted), (SELECT b FROM submitted), 'submitting twice returns the same job');
SELECT is((SELECT count(*)::integer FROM public.aijob WHERE incidentid = (SELECT inc FROM t)), 1,
          'two files, two submits -> one analyse job');
SELECT is((SELECT aisummarystatus::text FROM public.crimescene WHERE incidentid = (SELECT inc FROM t)),
          'processing', 'the submission shows "AI processing"');

SET LOCAL ROLE authenticated;
SELECT throws_ok('SELECT * FROM public.claim_next_job(''app'')', '42501', NULL,
                 'a citizen cannot claim jobs');
SELECT is((SELECT count(*)::integer FROM public.caseentity), 0, 'a citizen sees no case entities');
RESET ROLE;

-- ---------------------------------------------------------------------
-- Worker: claim, second claim gets nothing, save, finish
-- ---------------------------------------------------------------------
SET LOCAL ROLE service_role;
SELECT is((SELECT kind::text FROM public.claim_next_job('tap-worker')), 'analyse', 'the worker gets the job');
SELECT is((SELECT count(*)::integer FROM public.claim_next_job('tap-worker-2')), 0,
          'a second worker gets nothing');
SELECT is(
  public.ai_save_analysis((SELECT inc FROM t), jsonb_build_object(
    'model_version', 'tap',
    'files', jsonb_build_array(
      jsonb_build_object('mediaid', (SELECT min(mediaid) FROM public.media WHERE incidentid = (SELECT inc FROM t)),
        'capture_time', '2026-10-12T10:05:00+00:00',
        'detections', jsonb_build_array(
          jsonb_build_object('track_id', 1, 'detection_type', 'person', 'confidence', 0.9,
                             'first_seen_seconds', 1.5, 'last_seen_seconds', 4, 'frames_seen', 20,
                             'upper_clothing', 'black'),
          jsonb_build_object('track_id', 2, 'detection_type', 'vehicle', 'class_name', 'car',
                             'plate', 'nd 123-456', 'plate_confidence', 0.9),
          jsonb_build_object('track_id', 3, 'detection_type', 'weapon', 'class_name', 'long_gun',
                             'held_by_person', 1))),
      jsonb_build_object('mediaid', (SELECT max(mediaid) FROM public.media WHERE incidentid = (SELECT inc FROM t)),
        'error', 'cannot decode'))), 'tap summary')
  - 'removed',
  '{"files": 2, "detections": 3, "people": 1, "vehicles": 1, "weapons": 1}'::jsonb,
  'ai_save_analysis writes one row per tracked object');
SELECT is((SELECT (public.finish_job(jobid)).status::text FROM public.aijob
            WHERE incidentid = (SELECT inc FROM t)), 'done', 'finish_job marks the job done');
RESET ROLE;

SELECT is((SELECT licenceplatenumber::text FROM public.vehicledetail v JOIN public.detection d USING (detectionid)
            JOIN public.media m USING (mediaid) WHERE m.incidentid = (SELECT inc FROM t)),
          'ND123456', 'the plate is stored normalised');
SELECT is((SELECT weapontype::text FROM public.weapondetail w JOIN public.detection d USING (detectionid)
            JOIN public.media m USING (mediaid) WHERE m.incidentid = (SELECT inc FROM t)),
          'long_gun', 'long_gun is an allowed weapon type');
SELECT is((SELECT suspectstatus::text FROM public.detection d JOIN public.media m USING (mediaid)
            WHERE m.incidentid = (SELECT inc FROM t) AND d.detectiontype = 'person'),
          'possible', 'a person is a possible suspect, not a suspect');
SELECT is((SELECT array_agg(processingstatus::text ORDER BY mediaid) FROM public.media
            WHERE incidentid = (SELECT inc FROM t)),
          ARRAY['completed', 'failed'], 'the broken file is marked failed');

-- ---------------------------------------------------------------------
-- Accept into a case -> merge job; the admin can't fake AI output
-- ---------------------------------------------------------------------
DO $$ BEGIN PERFORM set_config('request.jwt.claims', '{"sub": "11111111-1111-1111-1111-111111111111", "role": "authenticated"}', true); END $$;
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE made ON COMMIT DROP AS
SELECT public.create_case('TAP case', NULL, ARRAY[(SELECT inc FROM t)]) AS caseid;
SELECT throws_ok(format('UPDATE public.cases SET aisummary = %L WHERE caseid = %s', 'fake',
                        (SELECT caseid FROM made)),
                 'P0001', 'AI fields are written by the analysis pipeline only',
                 'admins cannot write the AI summary');
SELECT is(public.get_case_evidence((SELECT caseid FROM made)) -> 'counts',
          '{"people": 0, "vehicles": 0, "weapons": 0}'::jsonb,
          'get_case_evidence works for the admin (empty until the worker merges)');
RESET ROLE;

SELECT is((SELECT array_agg(kind::text) FROM public.aijob
            WHERE caseid = (SELECT caseid FROM made) AND status = 'queued'),
          ARRAY['merge'], 'accepting queues a merge');

-- ---------------------------------------------------------------------
-- Suggestion rule (match_incidents)
-- ---------------------------------------------------------------------
INSERT INTO public.crimescene (location, datetime, reportedby, latitude, longitude)
SELECT 'Near', '2026-10-12 10:20+00'::timestamptz, citizen, -26.1076, 28.0597 FROM t       -- ~300 m, 20 min
UNION ALL
SELECT 'Far',  '2026-10-12 10:20+00', citizen, -25.7500, 28.1900 FROM t;     -- ~45 km

SELECT is((SELECT count(*)::integer FROM public.match_incidents(
             ARRAY[(SELECT incidentid FROM public.crimescene WHERE location = 'Near')],
             ARRAY[(SELECT inc FROM t)])), 1, '300 m and 20 min apart -> suggested');
SELECT is((SELECT count(*)::integer FROM public.match_incidents(
             ARRAY[(SELECT incidentid FROM public.crimescene WHERE location = 'Far')],
             ARRAY[(SELECT inc FROM t)])), 0, '45 km apart, no plate -> not suggested');

-- ---------------------------------------------------------------------
-- Deleting a case that has AI work still works
-- ---------------------------------------------------------------------
SELECT lives_ok(format('DELETE FROM public.cases WHERE caseid = %s', (SELECT caseid FROM made)),
                'a case can still be deleted');

SELECT * FROM finish();
ROLLBACK;
