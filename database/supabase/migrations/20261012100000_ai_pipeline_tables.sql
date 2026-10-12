-- =====================================================================
-- Argus Shield: AI pipeline in the database - TABLES AND COLUMNS
-- (docs: SUPABASE_AI_PIPELINE.md, sections 1-4, 6 and 8)
--
-- What this adds, so that a citizen's submission is analysed by the AI
-- worker and the results land in tables (not only in results.json):
--
--   aijob          the work queue: one row per thing the worker must do
--                  (analyse a submission, merge it into a case, ...)
--   aiworker       heartbeat of each running worker ("AI worker online")
--   caseentity     Person 1 / Vehicle 2 / Weapon 1 of a CASE: the people,
--                  vehicles and weapons combined over all its submissions
--   entitymatchrejection
--                  "No, this is not Person 2" - never asked again
--
--   detection      + one row per TRACKED object (not per frame): track id,
--                    seen from/to, details, crops, appearance fingerprint,
--                    and which case entity it belongs to (Person 2 ...)
--   weapondetail   + long_gun / machete allowed, + who was holding it
--   crimescene     + gpssource (file | phone | typed), aimerged
--   media          + latitude / longitude of each file
--   cases          + aisummary, aisummarystatus, aisummaryat
--
-- The functions and triggers that use these are in the next migration
-- (20261012100100_ai_pipeline_functions.sql). Only the AI worker (service
-- key) writes the AI columns; app users read them through RLS and the
-- functions (get_case_evidence, answer_entity_match ...).
--
--   cases 1 ──< caseentity 1 ──< detection (caseentityid, matchstatus)
--   caseentity (weapon) ── 0..1 caseentity (person holding it)
--   detection >──< caseentity   entitymatchrejection ("not this one")
--
-- Contents
--   1. pgvector                   5. weapondetail
--   2. aijob, aiworker            6. crimescene, media
--   3. caseentity, rejections     7. cases: AI summary
--   4. detection                  8. Privileges and RLS
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. pgvector: the appearance fingerprints (ai/appearance.py) are lists
--    of numbers; pgvector stores them and compares them fast (<=>).
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;


-- ---------------------------------------------------------------------
-- 2. Job queue
-- ---------------------------------------------------------------------
-- kind      what the worker does (ai/README / SUPABASE_AI_PIPELINE.md s.10)
--   analyse   run the pipeline on a submission's files, save the results
--   merge     combine an accepted submission into its case's people /
--             vehicles / weapons (case_matcher.merge_submission)
--   rematch   place one detection again after an admin said "No, not
--             Person 2" (skipping rejected pairs)
--   summary   re-vote a case's people / vehicles / weapons and rewrite the
--             case's AI summary
-- (Removing a submission from a case needs no job: the database unlinks
--  its pictures straight away and queues a 'summary' to re-vote.)
CREATE TABLE public.aijob (
  jobid       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind        varchar(20) NOT NULL
              CHECK (kind IN ('analyse', 'merge', 'rematch', 'summary')),
  -- CASCADE: a job for a deleted incident / case / detection has nothing
  -- left to do
  incidentid  integer REFERENCES public.crimescene (incidentid) ON DELETE CASCADE,
  caseid      integer REFERENCES public.cases (caseid) ON DELETE CASCADE,
  detectionid integer REFERENCES public.detection (detectionid) ON DELETE CASCADE,
  status      varchar(20) NOT NULL DEFAULT 'queued'
              CHECK (status IN ('queued', 'processing', 'done', 'failed')),
  attempts    smallint    NOT NULL DEFAULT 0,
  error       text,                       -- last error message
  workerid    text,                       -- which worker took it
  createdat   timestamptz NOT NULL DEFAULT now(),
  startedat   timestamptz,
  finishedat  timestamptz,
  -- each kind needs its own ids
  CONSTRAINT aijob_target_check CHECK (
    CASE kind
      WHEN 'analyse' THEN incidentid IS NOT NULL AND caseid IS NULL AND detectionid IS NULL
      WHEN 'merge'   THEN incidentid IS NOT NULL AND caseid IS NOT NULL AND detectionid IS NULL
      WHEN 'rematch' THEN caseid IS NOT NULL AND detectionid IS NOT NULL
      WHEN 'summary' THEN caseid IS NOT NULL AND incidentid IS NULL AND detectionid IS NULL
    END)
);

CREATE INDEX idx_aijob_status_created ON public.aijob (status, createdat);
CREATE INDEX idx_aijob_incidentid     ON public.aijob (incidentid);
CREATE INDEX idx_aijob_caseid         ON public.aijob (caseid);
CREATE INDEX idx_aijob_detectionid    ON public.aijob (detectionid);

-- The same work is never waiting twice (e.g. a double tap on Submit).
-- COALESCE so NULL ids compare equal. Only QUEUED jobs: while a job runs,
-- the same work may be queued once more (the data changed meanwhile, so
-- it must run again afterwards).
CREATE UNIQUE INDEX aijob_one_queued
  ON public.aijob (kind, COALESCE(incidentid, 0), COALESCE(caseid, 0),
                   COALESCE(detectionid, 0))
  WHERE status = 'queued';

-- Heartbeat: each worker upserts its row every ~30 s (ai_worker_heartbeat)
CREATE TABLE public.aiworker (
  workerid text        PRIMARY KEY,       -- e.g. 'gpu-laptop-1'
  lastseen timestamptz NOT NULL DEFAULT now(),
  gpu      text,                          -- e.g. 'RTX 3080'
  version  text                           -- pipeline / model version
);


-- ---------------------------------------------------------------------
-- 3. The people / vehicles / weapons of a case
-- ---------------------------------------------------------------------
-- One row = "Person 2" of case 7. Which detections (crops) belong to it is
-- detection.caseentityid + detection.matchstatus (section 4).
CREATE TABLE public.caseentity (
  entityid       integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  caseid         integer     NOT NULL REFERENCES public.cases (caseid) ON DELETE CASCADE,
  kind           varchar(10) NOT NULL CHECK (kind IN ('person', 'vehicle', 'weapon')),
  number         integer     NOT NULL CHECK (number > 0),   -- the 2 in "Person 2"
  -- combined, voted details (same keys as ai/case_matcher.py _revote)
  attributes     jsonb       NOT NULL DEFAULT '{}'::jsonb,
  coverpath      text,                                       -- clearest picture
  -- weapons: the person holding it
  heldbyentityid integer REFERENCES public.caseentity (entityid) ON DELETE SET NULL,
  -- what later submissions changed: [{field, old, new, submission}]
  updates        jsonb       NOT NULL DEFAULT '[]'::jsonb,
  updatedat      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT caseentity_number_key UNIQUE (caseid, kind, number),
  CONSTRAINT caseentity_heldby_check CHECK (heldbyentityid IS NULL OR kind = 'weapon'),
  CONSTRAINT caseentity_attributes_check CHECK (jsonb_typeof(attributes) = 'object'),
  CONSTRAINT caseentity_updates_check CHECK (jsonb_typeof(updates) = 'array')
);

CREATE INDEX idx_caseentity_heldby ON public.caseentity (heldbyentityid);

-- "No, this is not Person 2": the pair is never suggested again
CREATE TABLE public.entitymatchrejection (
  detectionid integer     NOT NULL REFERENCES public.detection (detectionid) ON DELETE CASCADE,
  entityid    integer     NOT NULL REFERENCES public.caseentity (entityid) ON DELETE CASCADE,
  rejectedby  integer     REFERENCES public."User" (userid),
  rejectedat  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (detectionid, entityid)
);

CREATE INDEX idx_entitymatchrejection_entity ON public.entitymatchrejection (entityid);
CREATE INDEX idx_entitymatchrejection_by     ON public.entitymatchrejection (rejectedby);


-- ---------------------------------------------------------------------
-- 4. detection: one row per tracked object, filled from results.json
-- ---------------------------------------------------------------------
-- Existing columns keep their meaning: frametimestamp = time of the
-- clearest view, boundingbox, confidencescore, modelversion.
ALTER TABLE public.detection
  -- results.json model_version is longer than 50 characters
  -- ('yolo26s+argus_tracker+spectrico-mobilenetv3+fastalpr-...')
  ALTER COLUMN modelversion TYPE varchar(200),
  ADD COLUMN trackid      integer,                -- track_id (per file)
  ADD COLUMN firstseen    numeric(10,3),          -- first_seen_seconds
  ADD COLUMN lastseen     numeric(10,3),          -- last_seen_seconds
  ADD COLUMN framesseen   integer,                -- frames_seen
  -- everything else the AI said about it: clothing colours + shares,
  -- face size, make / colour top-3, plate reads ...
  ADD COLUMN attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- its pictures in the 'submissions' bucket, with what each one shows:
  -- [{"path": "42/ai/<run>/1_clip/person_3.png", "type": "person"}, ...]
  -- type = person | face | vehicle | plate | weapon
  ADD COLUMN crops        jsonb NOT NULL DEFAULT '[]'::jsonb,
  -- appearance fingerprint (ai/appearance.py): how the person / vehicle
  -- looks (clothing, overall look) - NOT face recognition
  ADD COLUMN appearance   extensions.vector(512), -- appearance.embedding
  ADD COLUMN colourhist   extensions.vector(96),  -- appearance.colour_hist
  -- membership of a case's Person / Vehicle / Weapon (section 3)
  ADD COLUMN caseentityid integer REFERENCES public.caseentity (entityid) ON DELETE SET NULL,
  --   first      it started this entity
  --   auto       the AI is sure it is the same (same plate, very alike)
  --   confirmed  an admin answered "Yes, this is Person 2"
  --   suggested  open question: "Is this Person 2?"
  ADD COLUMN matchstatus  varchar(12)
             CHECK (matchstatus IN ('first', 'auto', 'confirmed', 'suggested')),
  ADD COLUMN matchscore   numeric(5,3),
  ADD COLUMN matchreasons text[],                 -- {"looks 81% alike", ...}
  ADD CONSTRAINT detection_match_check
    CHECK ((caseentityid IS NULL) = (matchstatus IS NULL)),
  ADD CONSTRAINT detection_seen_check
    CHECK (firstseen IS NULL OR lastseen IS NULL OR firstseen <= lastseen),
  ADD CONSTRAINT detection_attributes_check CHECK (jsonb_typeof(attributes) = 'object'),
  ADD CONSTRAINT detection_crops_check CHECK (jsonb_typeof(crops) = 'array'),
  -- a re-run of the same file updates its rows instead of adding more
  ADD CONSTRAINT detection_track_key UNIQUE (mediaid, detectiontype, trackid);

CREATE INDEX idx_detection_caseentityid ON public.detection (caseentityid);


-- ---------------------------------------------------------------------
-- 5. weapondetail
-- ---------------------------------------------------------------------
-- The weapon model outputs long_gun and machete
ALTER TABLE public.weapondetail DROP CONSTRAINT weapondetail_weapontype_check;
ALTER TABLE public.weapondetail ADD CONSTRAINT weapondetail_weapontype_check
  CHECK (weapontype IN ('handgun', 'long_gun', 'rifle', 'shotgun', 'knife', 'machete',
                        'explosive', 'other', 'unknown'));

-- Who was holding it (results.json held_by_person -> that person's
-- detection). suspectid stays for investigators: a suspect row only exists
-- once an investigator CONFIRMS the person (POPIA, migration
-- 20261006090000), so the AI can't fill it in.
ALTER TABLE public.weapondetail
  ADD COLUMN heldbydetectionid integer
      REFERENCES public.detection (detectionid) ON DELETE SET NULL;

CREATE INDEX idx_weapondetail_heldby ON public.weapondetail (heldbydetectionid);


-- ---------------------------------------------------------------------
-- 6. Where / when
-- ---------------------------------------------------------------------
ALTER TABLE public.crimescene
  -- where latitude / longitude came from:
  --   file   GPS inside the video / photo (set by the AI worker)
  --   phone  the phone's GPS when the citizen submitted
  --   typed  no GPS, only the typed location
  ADD COLUMN gpssource varchar(10) CHECK (gpssource IN ('file', 'phone', 'typed')),
  -- true once the submission's AI results are combined into its case's
  -- people / vehicles / weapons (set by the worker, cleared when it leaves
  -- the case or is analysed again)
  ADD COLUMN aimerged  boolean NOT NULL DEFAULT false;

-- Existing rows: GPS so far always came from the phone
UPDATE public.crimescene
   SET gpssource = CASE WHEN latitude IS NOT NULL THEN 'phone' ELSE 'typed' END;

-- A submission can mix files from different spots: GPS per file
ALTER TABLE public.media
  ADD COLUMN latitude  numeric(9,6) CHECK (latitude  BETWEEN -90  AND 90),
  ADD COLUMN longitude numeric(9,6) CHECK (longitude BETWEEN -180 AND 180),
  ADD CONSTRAINT media_latlong_check CHECK ((latitude IS NULL) = (longitude IS NULL));


-- ---------------------------------------------------------------------
-- 7. Case AI summary (same columns as crimescene's submission summary)
-- ---------------------------------------------------------------------
ALTER TABLE public.cases
  ADD COLUMN aisummary       text CHECK (char_length(aisummary) <= 600),
  ADD COLUMN aisummarystatus varchar(20) NOT NULL DEFAULT 'none'
             CHECK (aisummarystatus IN ('none', 'processing', 'ready', 'outdated', 'failed')),
  ADD COLUMN aisummaryat     timestamptz;


-- ---------------------------------------------------------------------
-- 8. Privileges and RLS
--    aijob, aiworker, entitymatchrejection: service key only (no policies
--    = app users can't touch them; admins see the queue through
--    ai_worker_status() and answer through answer_entity_match()).
--    caseentity: admins and investigators assigned to the case can read.
--    Nobody writes these from the app.
-- ---------------------------------------------------------------------
ALTER TABLE public.aijob                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.aiworker             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.caseentity           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.entitymatchrejection ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.aijob, public.aiworker, public.entitymatchrejection
  FROM anon, authenticated;
REVOKE ALL ON public.caseentity FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, TRIGGER, REFERENCES
  ON public.caseentity FROM authenticated;
GRANT ALL ON public.aijob, public.aiworker, public.caseentity,
             public.entitymatchrejection TO service_role;

CREATE POLICY "caseentity_select" ON public.caseentity
  FOR SELECT TO authenticated
  USING (
       (SELECT public.current_user_role()) = 'admin'
    OR public.is_assigned_to_case(caseid)
  );

-- detection's new columns are covered by the existing detection_select
-- policy (admin, or investigator assigned to the case; never citizens).
-- The protect_detection_ai trigger (next migration) stops app users from
-- changing them.
