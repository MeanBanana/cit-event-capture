-- On/off switch for the Android APK download on the website.
--
-- We're on the free Supabase plan, so when we demo to a big room we don't
-- want a few hundred people installing the app and hammering the project.
-- Root flips this off from the web console, the landing page then hides the
-- Download button and the Netlify edge function (apk-guard.ts) refuses the
-- direct /downloads/ link too.
--
-- site_settings is a single row. Nobody touches it directly:
--   apk_download_enabled()           anyone (anon too), the website reads it
--   set_apk_download_enabled(bool)   root only, from the console

-- --- 1. site_settings (one row only)
CREATE TABLE public.site_settings (
  id                    boolean PRIMARY KEY DEFAULT true CHECK (id),
  apk_download_enabled  boolean NOT NULL DEFAULT true,
  updatedat             timestamptz NOT NULL DEFAULT now(),
  updatedby             integer REFERENCES public."User"(userid) ON DELETE SET NULL
);

INSERT INTO public.site_settings (id) VALUES (true);

ALTER TABLE public.site_settings ENABLE ROW LEVEL SECURITY;


-- --- 2. apk_download_enabled
CREATE OR REPLACE FUNCTION public.apk_download_enabled()
  RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT COALESCE((SELECT s.apk_download_enabled FROM public.site_settings s WHERE s.id), true)
$$;


-- --- 3. set_apk_download_enabled
CREATE OR REPLACE FUNCTION public.set_apk_download_enabled(p_enabled boolean)
  RETURNS boolean
  LANGUAGE plpgsql
  VOLATILE SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_root_admin() THEN
    RAISE EXCEPTION 'Only the root administrator can switch the app download on or off.'
      USING ERRCODE = '42501';
  END IF;
  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'Say whether the download should be on or off.' USING ERRCODE = '22004';
  END IF;

  INSERT INTO public.site_settings (id, apk_download_enabled, updatedat, updatedby)
    VALUES (true, p_enabled, now(), public.current_user_id())
    ON CONFLICT (id) DO UPDATE
    SET apk_download_enabled = EXCLUDED.apk_download_enabled,
        updatedat            = EXCLUDED.updatedat,
        updatedby            = EXCLUDED.updatedby;
  RETURN p_enabled;
END;
$$;


-- --- privileges (only through the functions above)
REVOKE ALL ON public.site_settings FROM PUBLIC, anon, authenticated;
GRANT  ALL ON public.site_settings TO service_role;

REVOKE EXECUTE ON FUNCTION public.apk_download_enabled()              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.set_apk_download_enabled(boolean)   FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.apk_download_enabled()              TO anon, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.set_apk_download_enabled(boolean)   TO authenticated, service_role;
