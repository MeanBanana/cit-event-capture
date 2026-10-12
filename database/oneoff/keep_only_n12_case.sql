-- keep_only_n12_case.sql - ONE-OFF clean-up of test data (NOT a migration:
-- don't move it into supabase/migrations).
--
-- Keeps ONE case - the one whose title contains "N12" and "northbound" -
-- and the submissions in it. Deletes every other case and every other
-- submission (accepted, pending, rejected, duplicate), with their media
-- rows, AI detections, suspects, AI jobs and history. Users are kept.
--
-- Run in Supabase: Dashboard -> SQL Editor -> New query.
--   STEP 1: paste only the PREVIEW part, Run, check the lists.
--   STEP 2: paste the DELETE part, Run. It is one transaction: if anything
--           fails (or there isn't exactly one N12 northbound case) nothing
--           is deleted.
--   STEP 3: on the GPU PC:  python backend\cleanup_storage.py   (the files
--           in the bucket - Supabase doesn't allow deleting those from SQL)
-- This cannot be undone.


-- =========================== PREVIEW (deletes nothing) ===================
SELECT c.caseid, c.title, c.status,
       CASE WHEN c.title ILIKE '%N12%' AND c.title ILIKE '%northbound%'
            THEN 'KEEP' ELSE 'delete' END AS action,
       (SELECT count(*) FROM public.crimescene cs WHERE cs.caseid = c.caseid) AS submissions
FROM public.cases c
ORDER BY action DESC, c.caseid;

SELECT cs.incidentid, cs.location, cs.reviewstatus, cs.caseid,
       CASE WHEN cs.caseid IN (SELECT caseid FROM public.cases
                                WHERE title ILIKE '%N12%' AND title ILIKE '%northbound%')
            THEN 'KEEP' ELSE 'delete' END AS action
FROM public.crimescene cs
ORDER BY action DESC, cs.incidentid;


-- =========================== DELETE ======================================
BEGIN;

CREATE TEMP TABLE keep_case ON COMMIT DROP AS
  SELECT caseid FROM public.cases
   WHERE title ILIKE '%N12%' AND title ILIKE '%northbound%';

DO $$
DECLARE n integer := (SELECT count(*) FROM keep_case);
BEGIN
  IF n <> 1 THEN
    RAISE EXCEPTION 'Expected exactly 1 case with N12 + northbound in its title, found %. Nothing deleted.', n;
  END IF;
END $$;

CREATE TEMP TABLE gone_case ON COMMIT DROP AS
  SELECT caseid FROM public.cases WHERE caseid NOT IN (SELECT caseid FROM keep_case);

CREATE TEMP TABLE gone_incident ON COMMIT DROP AS
  SELECT incidentid FROM public.crimescene
   WHERE caseid IS NULL OR caseid NOT IN (SELECT caseid FROM keep_case);

CREATE TEMP TABLE gone_detection ON COMMIT DROP AS
  SELECT d.detectionid FROM public.detection d
    JOIN public.media m ON m.mediaid = d.mediaid
   WHERE m.incidentid IN (SELECT incidentid FROM gone_incident);

-- history of what goes
DELETE FROM public.caseevent
 WHERE caseid IN (SELECT caseid FROM gone_case)
    OR incidentid IN (SELECT incidentid FROM gone_incident);

-- a KEPT submission marked as a duplicate of one that goes: it stays in
-- the N12 case as an accepted submission
UPDATE public.crimescene SET reviewstatus = 'accepted', duplicateof = NULL
 WHERE duplicateof IN (SELECT incidentid FROM gone_incident)
   AND incidentid NOT IN (SELECT incidentid FROM gone_incident);

-- AI / investigator rows of the deleted submissions' detections
DELETE FROM public.weapondetail  WHERE detectionid IN (SELECT detectionid FROM gone_detection);
DELETE FROM public.vehicledetail WHERE detectionid IN (SELECT detectionid FROM gone_detection);
DELETE FROM public.correctionlog WHERE detectionid IN (SELECT detectionid FROM gone_detection);
DELETE FROM public.suspect
 WHERE detectionid IN (SELECT detectionid FROM gone_detection)
    OR incidentid  IN (SELECT incidentid  FROM gone_incident);
DELETE FROM public.aijob
 WHERE incidentid  IN (SELECT incidentid  FROM gone_incident)
    OR detectionid IN (SELECT detectionid FROM gone_detection)
    OR caseid      IN (SELECT caseid      FROM gone_case);

DELETE FROM public.detection  WHERE detectionid IN (SELECT detectionid FROM gone_detection);
DELETE FROM public.media      WHERE incidentid  IN (SELECT incidentid  FROM gone_incident);
DELETE FROM public.crimescene WHERE incidentid  IN (SELECT incidentid  FROM gone_incident);

-- the cases (their assignments, AI people / vehicles / weapons and match
-- answers go with them)
DELETE FROM public.cases WHERE caseid IN (SELECT caseid FROM gone_case);

-- the "case deleted" history lines the line above just wrote
DELETE FROM public.caseevent
 WHERE eventtype = 'case_deleted' AND occurredat >= now();

COMMIT;

-- what is left
SELECT 'cases' AS what, count(*) FROM public.cases
UNION ALL SELECT 'submissions', count(*) FROM public.crimescene
UNION ALL SELECT 'media files', count(*) FROM public.media
UNION ALL SELECT 'AI detections', count(*) FROM public.detection;
