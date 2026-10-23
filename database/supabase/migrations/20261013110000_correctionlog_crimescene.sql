-- Every correction now records which crime scene it belongs to.
--
-- correctionlog only had detectionid, so getting a scene's corrections meant
-- going correctionlog -> detection -> media -> crimescene every time. Now the
-- row carries incidentid directly.
--
--   crimescene 1 --< correctionlog >-- 1 detection
--                         `---------- 1 "User" (correctedby)
--
-- A trigger fills incidentid in from the detection, so it can never disagree
-- with the detection that was corrected. Existing rows get backfilled below.

ALTER TABLE public.correctionlog
  ADD COLUMN incidentid integer REFERENCES public.crimescene (incidentid);

UPDATE public.correctionlog c
   SET incidentid = m.incidentid
  FROM public.detection d
  JOIN public.media m ON m.mediaid = d.mediaid
 WHERE d.detectionid = c.detectionid;

ALTER TABLE public.correctionlog ALTER COLUMN incidentid SET NOT NULL;

-- a scene's log, newest first
CREATE INDEX idx_correctionlog_incident_time
  ON public.correctionlog (incidentid, correctiontimestamp DESC);

-- always the corrected detection's scene, whatever the caller passed in
CREATE OR REPLACE FUNCTION public.set_correctionlog_incident()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  SELECT m.incidentid INTO NEW.incidentid
  FROM public.detection d
  JOIN public.media m ON m.mediaid = d.mediaid
  WHERE d.detectionid = NEW.detectionid;
  IF NEW.incidentid IS NULL THEN
    RAISE EXCEPTION 'Detection % not found', NEW.detectionid;
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.set_correctionlog_incident() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER set_correctionlog_incident
  BEFORE INSERT OR UPDATE OF detectionid, incidentid ON public.correctionlog
  FOR EACH ROW EXECUTE FUNCTION public.set_correctionlog_incident();


-- --- the crime scene functions read the new column directly

-- cards: same as 20261013100000, but the correction count uses incidentid
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
         (SELECT count(*) FROM public.correctionlog c WHERE c.incidentid = s.incidentid)::integer
  FROM scene s
  ORDER BY COALESCE((SELECT min(m.capturetimestamp) FROM public.media m
                      WHERE m.incidentid = s.incidentid), s.datetime), s.incidentid;
END;
$$;

-- scene page: same as 20261013100000, but the log comes via incidentid and
-- every entry says which scene it's from
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
                'incident_id',   c.incidentid,
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
              WHERE c.incidentid = p_incidentid
              ORDER BY c.correctiontimestamp DESC, c.correctionid DESC
              LIMIT 100) c
       LEFT JOIN public."User" u ON u.userid = c.correctedby), '[]'::jsonb));
END;
$$;
