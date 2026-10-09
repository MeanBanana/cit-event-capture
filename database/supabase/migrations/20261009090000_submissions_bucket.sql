-- =====================================================================
-- Argus Shield: storage bucket for citizen submissions
--
-- One private bucket, 'submissions' (Supabase Storage, S3-compatible),
-- holds everything that belongs to an incident, one folder per incident:
--
--   <incidentid>/media/<file>                     footage the citizen uploaded
--   <incidentid>/ai/<run>/results.json            one AI pipeline run
--   <incidentid>/ai/<run>/1_clip1/vehicle_3.png   its pictures, per file
--
-- The AI results stay a JSON FILE, not table rows: one submission can
-- produce hundreds of detections, so a row per detection would grow the
-- database very fast. The database only keeps ONE pointer per clip
-- (media.airesultpath). <run> = when the analysis ran, so re-running
-- never overwrites an earlier result. Uploaded by backend/upload_results.py.
--
-- Upload flow (app):
--   1. insert crimescene  (as now)
--   2. upload the file to  <incidentid>/media/<uuid>.<ext>   (no upsert)
--   3. insert media with storagepath = that same path
--
-- Who may do what:
--   citizen       upload footage to incidents THEY reported; read that
--                 footage back. Never sees the ai/ folder (it holds crops
--                 of other people's faces and plates - POPIA).
--   investigator  read and add footage for incidents in their assigned
--                 cases, read the AI results.
--   admin         everything above, for every incident.
--   pipeline      service key (bypasses RLS): reads footage, writes ai/.
--   Nobody changes or deletes files from the app: footage is evidence.
--
-- Contents
--   1. Bucket                3. media.storagepath must be in its folder
--   2. media AI pointer      4. Storage policies
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Bucket
-- ---------------------------------------------------------------------
-- 50 MiB = the project's upload limit (config.toml [storage]). On the
-- free plan that is also the maximum; original-quality phone video
-- (needed for readable plates) is often bigger, so on Pro raise both.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('submissions', 'submissions', false,
        52428800,
        ARRAY[
          -- footage (the formats the AI pipeline accepts)
          'video/mp4', 'video/quicktime', 'video/x-msvideo', 'video/x-matroska',
          'video/x-m4v', 'video/3gpp', 'video/webm',
          'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif',
          'image/bmp', 'image/tiff', 'image/gif',
          -- AI results
          'application/json'])
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;


-- ---------------------------------------------------------------------
-- 2. AI results pointer on media (one per clip, not one per detection)
-- ---------------------------------------------------------------------
ALTER TABLE public.media
  ADD COLUMN airesultpath text,          -- newest results.json in 'submissions'
  ADD COLUMN airesultat   timestamptz;   -- when that analysis ran

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
                              OR NEW.airesultat    IS NOT NULL))
    OR (TG_OP = 'UPDATE' AND (NEW.aidescription IS DISTINCT FROM OLD.aidescription
                              OR NEW.aidescribedat IS DISTINCT FROM OLD.aidescribedat
                              OR NEW.airesultpath  IS DISTINCT FROM OLD.airesultpath
                              OR NEW.airesultat    IS DISTINCT FROM OLD.airesultat)))
  THEN
    RAISE EXCEPTION 'AI fields are written by the analysis pipeline only';
  END IF;
  RETURN NEW;
END;
$$;


-- ---------------------------------------------------------------------
-- 3. media.storagepath must point into the incident's own media folder,
--    so nobody can attach a file from someone else's incident.
--    (App users only; the service key may still import other paths.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_media_storagepath()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon')
     AND NEW.storagepath !~ ('^' || NEW.incidentid || '/media/[^/]+$')
  THEN
    RAISE EXCEPTION 'storagepath must be %/media/<file> in the submissions bucket', NEW.incidentid;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER check_media_storagepath
  BEFORE INSERT OR UPDATE OF storagepath, incidentid ON public.media
  FOR EACH ROW EXECUTE FUNCTION public.check_media_storagepath();


-- ---------------------------------------------------------------------
-- 4. Storage policies
-- ---------------------------------------------------------------------
-- True when the signed-in user reported the incident.
-- SECURITY DEFINER like the other policy helpers.
CREATE OR REPLACE FUNCTION public.reported_by_me(p_incidentid integer)
  RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.crimescene cs
    WHERE cs.incidentid = p_incidentid
      AND cs.reportedby = public.current_user_id()
  )
$$;

-- Incident id from an object name ('42/media/x.mp4' -> 42), NULL when
-- the name doesn't start with a number (so a cast can never fail).
CREATE OR REPLACE FUNCTION public.submission_incident(p_name text)
  RETURNS integer
  LANGUAGE sql IMMUTABLE
  SET search_path = ''
AS $$
  SELECT CASE WHEN split_part(p_name, '/', 1) ~ '^[0-9]{1,9}$'
              THEN split_part(p_name, '/', 1)::integer END
$$;

REVOKE EXECUTE ON FUNCTION public.reported_by_me(integer)   FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.submission_incident(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.reported_by_me(integer)   TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.submission_incident(text) TO authenticated, service_role;

-- Read: admin anything; assigned investigator the whole incident folder
-- (footage + AI results); the reporting citizen only the media/ folder.
CREATE POLICY "submissions_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'submissions'
    AND (
         (SELECT public.current_user_role()) = 'admin'
      OR COALESCE(public.is_assigned_to(public.submission_incident(name)), false)
      OR (split_part(name, '/', 2) = 'media'
          AND COALESCE(public.reported_by_me(public.submission_incident(name)), false))
    )
  );

-- Upload: footage only, straight into <incidentid>/media/<file>, for an
-- incident you reported, are assigned to, or (admin) any. Same rule as
-- the media_insert policy. The ai/ folder is pipeline-only.
CREATE POLICY "submissions_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'submissions'
    AND name ~ '^[0-9]{1,9}/media/[^/]+$'
    AND (
         (SELECT public.current_user_role()) = 'admin'
      OR public.is_assigned_to(public.submission_incident(name))
      OR public.reported_by_me(public.submission_incident(name))
    )
  );

-- No UPDATE / DELETE policies on purpose: uploaded footage and AI
-- results can't be replaced or removed from the app (chain of evidence).
-- Upload without upsert; an admin can clean up with the service key.
