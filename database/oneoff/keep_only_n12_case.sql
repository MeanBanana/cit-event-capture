-- One-off clean-up of test data. This is NOT a migration, don't move it into
-- supabase/migrations.
--
-- Keeps a single case (the one with "N12" and "northbound" in the title) and
-- its submissions. Every other case and submission gets deleted, along with
-- their media rows, detections, suspects, AI jobs and history. Users stay.
--
-- Run it in the dashboard's SQL Editor in two goes:
--   1. paste just the PREVIEW part and check the lists look right
--   2. paste the DELETE part. It's one transaction, so if anything fails (or
--      there isn't exactly one N12 northbound case) nothing gets deleted.
--   3. then on the GPU PC run  python backend/cleanup_storage.py  to clear
--      the bucket, since Supabase won't delete storage files from SQL.
-- There's no undo.


-- ---- PREVIEW (doesn't delete anything)
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


-- ---- DELETE
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

-- history for the stuff that's going
DELETE FROM public.caseevent
 WHERE caseid IN (SELECT caseid FROM gone_case)
    OR incidentid IN (SELECT incidentid FROM gone_incident);

-- a submission we're keeping that was marked a duplicate of one that's going
-- stays in the N12 case as accepted
UPDATE public.crimescene SET reviewstatus = 'accepted', duplicateof = NULL
 WHERE duplicateof IN (SELECT incidentid FROM gone_incident)
   AND incidentid NOT IN (SELECT incidentid FROM gone_incident);

-- AI and investigator rows hanging off the deleted detections
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

-- the cases themselves (assignments, AI entities and match answers go with them)
DELETE FROM public.cases WHERE caseid IN (SELECT caseid FROM gone_case);

-- and the "case deleted" history lines the delete above just wrote
DELETE FROM public.caseevent
 WHERE eventtype = 'case_deleted' AND occurredat >= now();

COMMIT;

-- what's left
SELECT 'cases' AS what, count(*) FROM public.cases
UNION ALL SELECT 'submissions', count(*) FROM public.crimescene
UNION ALL SELECT 'media files', count(*) FROM public.media
UNION ALL SELECT 'AI detections', count(*) FROM public.detection;
