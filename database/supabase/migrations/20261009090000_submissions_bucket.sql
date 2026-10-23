-- The 'submissions' storage bucket.
--
-- One private bucket with a folder per incident:
--   <incidentid>/media/<file>                     what the citizen uploaded
--   <incidentid>/ai/<run>/results.json            one AI run
--   <incidentid>/ai/<run>/1_clip1/vehicle_3.png   that run's crops
--
-- AI results stay as a JSON file rather than rows, since a single submission
-- can have hundreds of detections. The database just keeps one pointer per
-- clip (media.airesultpath). <run> is a timestamp so re-runs never overwrite
-- older results. backend/upload_results.py does the uploading.
--
-- The app uploads like this: insert the crimescene, upload each file to
-- <incidentid>/media/<uuid>.<ext> (no upsert), then insert the media row with
-- that same path.
--
-- Access:
--   citizen       upload and read footage on incidents they reported. Never
--                 the ai/ folder though, that has crops of other people's
--                 faces and plates (POPIA).
--   investigator  read and add footage on their assigned cases' incidents,
--                 and read the AI results
--   admin         all of the above, for everything
--   pipeline      service key, bypasses RLS, reads footage and writes ai/
-- Nobody can change or delete files from the app. Footage is evidence.


-- --- 1. bucket
-- 50 MiB matches the project upload limit in config.toml. That's also the
-- free plan's max, and full-quality phone video (which you need to read
-- plates) is often bigger, so bump both if we go Pro.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('submissions', 'submissions', false,
        52428800,
        ARRAY[
          -- footage, same formats the pipeline accepts
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


-- --- 2. AI results pointer on media (per clip, not per detection)
ALTER TABLE public.media
  ADD COLUMN airesultpath text,          -- latest results.json in the bucket
  ADD COLUMN airesultat   timestamptz;   -- when that run happened

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


-- --- 3. media.storagepath has to be inside the incident's own media folder,
-- so nobody can attach a file from somebody else's incident. Only applies to
-- app users, the service key can still import from elsewhere.
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


-- --- 4. storage policies
-- did the signed-in user report this incident? SECURITY DEFINER like the
-- other policy helpers.
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

-- Incident id from an object name ('42/media/x.mp4' -> 42). NULL if the name
-- doesn't start with a number, so the cast can't blow up.
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

-- Read: admins anything, assigned investigators the whole incident folder
-- (footage and AI results), the reporting citizen only media/.
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
-- incident you reported or are assigned to (admins: any). Same rule as the
-- media_insert policy. ai/ is pipeline only.
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

-- Deliberately no UPDATE/DELETE policies. Uploaded footage and AI results
-- can't be replaced or removed from the app, chain of evidence and all that.
-- If something really needs cleaning up an admin can use the service key.
