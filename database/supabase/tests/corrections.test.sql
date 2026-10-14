-- =====================================================================
-- pgTAP tests for 20261013100000_crime_scenes_and_corrections.sql
-- (structure and privileges; behaviour is in tests/test_corrections_db.py)
--
--     supabase start
--     supabase test db
-- =====================================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;

SELECT plan(29);

-- Structure
SELECT has_column('public', 'correctionlog', 'fieldname', 'correctionlog.fieldname');
SELECT has_column('public', 'correctionlog', 'note', 'correctionlog.note');
SELECT has_column('public', 'detection', 'corrections', 'detection.corrections');
SELECT has_column('public', 'correctionlog', 'incidentid', 'correctionlog.incidentid');
SELECT col_not_null('public', 'correctionlog', 'incidentid', 'every correction has a crime scene');
SELECT fk_ok('public', 'correctionlog', 'incidentid', 'public', 'crimescene', 'incidentid',
             'correctionlog.incidentid references crimescene');
SELECT has_trigger('public', 'correctionlog', 'set_correctionlog_incident',
                   'the crime scene is taken from the corrected detection');
SELECT col_not_null('public', 'detection', 'corrections', 'detection.corrections is never null');
SELECT has_function('public', 'correct_detection', ARRAY['integer', 'text', 'text', 'text']);
SELECT has_function('public', 'list_case_crime_scenes', ARRAY['integer']);
SELECT has_function('public', 'get_crime_scene', ARRAY['integer']);
SELECT has_trigger('public', 'detection', 'detection_keep_dismissed_out',
                   'dismissed detections are kept out of case entities');

-- Corrections only through correct_detection()
SELECT policies_are('public', 'correctionlog', ARRAY['correctionlog_select'],
                    'correctionlog: read policy only');
SELECT policies_are('public', 'vehicledetail', ARRAY['vehicledetail_select'],
                    'vehicledetail: read policy only');
SELECT policies_are('public', 'weapondetail', ARRAY['weapondetail_select'],
                    'weapondetail: read policy only');
SELECT table_privs_are('public', 'correctionlog', 'authenticated', ARRAY['SELECT'],
                       'app users can only read the corrections log');
SELECT table_privs_are('public', 'correctionlog', 'anon', ARRAY[]::text[],
                       'signed-out users have no access to the corrections log');
SELECT ok(NOT has_table_privilege('authenticated', 'public.vehicledetail', 'UPDATE'),
          'app users cannot update vehicledetail directly');
SELECT ok(NOT has_table_privilege('authenticated', 'public.weapondetail', 'UPDATE'),
          'app users cannot update weapondetail directly');

-- Functions
SELECT function_privs_are('public', 'correct_detection', ARRAY['integer', 'text', 'text', 'text'],
                          'authenticated', ARRAY['EXECUTE'], 'app users can correct (it checks who)');
SELECT function_privs_are('public', 'correct_detection', ARRAY['integer', 'text', 'text', 'text'],
                          'anon', ARRAY[]::text[], 'signed-out users cannot correct');
SELECT function_privs_are('public', 'get_crime_scene', ARRAY['integer'], 'anon', ARRAY[]::text[],
                          'signed-out users cannot read a crime scene');
SELECT function_privs_are('public', 'crime_scene_analysis', ARRAY['integer'], 'authenticated',
                          ARRAY[]::text[], 'crime_scene_analysis is internal');

-- Helpers
SELECT is(public.correctable_fields('weapon'), ARRAY['weapon_type', 'dismissed'],
          'weapons: type and dismissed');
SELECT is(public.detection_value('{"plate": "nd 123-456"}'::jsonb, '{}'::jsonb, 'plate'), 'ND123456',
          'the AI plate, normalised');
SELECT is(public.detection_value('{"make": "Toyota"}'::jsonb, '{"make": "Nissan"}'::jsonb, 'make'), 'Nissan',
          'a correction wins over the AI');
SELECT is(public.detection_ai_value('{"class_name": "Pistol"}'::jsonb, 'weapon_type'), 'other',
          'a weapon class weapondetail does not know is other');
SELECT is(public.detection_ai_value('{"class_name": "long_gun"}'::jsonb, 'weapon_type'), 'long_gun',
          'a known weapon class is kept');
SELECT is(public.detection_ai_value('{}'::jsonb, 'weapon_type'), NULL,
          'no weapon class: the AI did not say');

SELECT * FROM finish();
ROLLBACK;
