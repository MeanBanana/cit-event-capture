-- =====================================================================
-- Argus Shield: connect public."User" to Supabase Auth + role-based RLS
--
-- Roles (from Deliverable 3):
--   citizen      - self-registers, submits footage, sees own submissions/profile
--   investigator - created by an admin, sees only assigned cases + their evidence
--   admin        - sees and manages everything
--
-- The Python CV pipeline should use the service_role key, which bypasses RLS,
-- to write detection / vehicledetail rows and update media.processingstatus.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Link public."User" to auth.users (Supabase Auth now owns passwords)
-- ---------------------------------------------------------------------
ALTER TABLE public."User"
  ADD COLUMN authid uuid UNIQUE REFERENCES auth.users (id) ON DELETE SET NULL;
-- SET NULL (not CASCADE): if an auth account is deleted, the profile stays so
-- the evidence trail (reportedby, uploadedby, correctedby...) is preserved.

-- Supabase Auth stores and checks passwords; never keep a copy in public.
ALTER TABLE public."User" DROP COLUMN passwordhash;


-- ---------------------------------------------------------------------
-- 2. Helper functions used by the policies
--    SECURITY DEFINER so they can read "User"/caseassignment without
--    triggering those tables' own RLS (avoids infinite recursion).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.current_user_id()
  RETURNS integer
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT userid FROM public."User" WHERE authid = auth.uid()
$$;

CREATE OR REPLACE FUNCTION public.current_user_role()
  RETURNS text
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT role::text FROM public."User" WHERE authid = auth.uid()
$$;

-- True when the signed-in investigator has an ACTIVE assignment on the case
CREATE OR REPLACE FUNCTION public.is_assigned_to(p_incidentid integer)
  RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.caseassignment ca
    WHERE ca.incidentid = p_incidentid
      AND ca.assignedto = public.current_user_id()
      AND ca.assignmentstatus = 'active'
  )
$$;

-- True when the signed-in user may see a detection (admin, or assigned
-- investigator on the case the detection's media belongs to)
CREATE OR REPLACE FUNCTION public.can_view_detection(p_detectionid integer)
  RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
  SELECT public.current_user_role() = 'admin'
      OR EXISTS (
           SELECT 1
           FROM public.detection d
           JOIN public.media m ON m.mediaid = d.mediaid
           WHERE d.detectionid = p_detectionid
             AND public.is_assigned_to(m.incidentid)
         )
$$;

REVOKE EXECUTE ON FUNCTION public.current_user_id()           FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.current_user_role()         FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.is_assigned_to(integer)     FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.can_view_detection(integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.current_user_id()           TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.current_user_role()         TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.is_assigned_to(integer)     TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.can_view_detection(integer) TO authenticated, service_role;


-- ---------------------------------------------------------------------
-- 3. Auto-create a profile row when someone signs up
--    Everyone who signs up is a CITIZEN. Role is never taken from the
--    client; admins promote investigators afterwards.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
  RETURNS trigger
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  INSERT INTO public."User" (authid, fullname, email, role)
  VALUES (
    NEW.id,
    COALESCE(NULLIF(NEW.raw_user_meta_data ->> 'fullname', ''), split_part(NEW.email, '@', 1)),
    NEW.email,
    'citizen'
  );
  RETURN NEW;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.handle_new_auth_user() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();


-- ---------------------------------------------------------------------
-- 4. Stop non-admins from changing their own role/badge/email/link
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.protect_user_columns()
  RETURNS trigger
  LANGUAGE plpgsql
  SET search_path = ''
AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon')
     AND public.current_user_role() IS DISTINCT FROM 'admin'
     AND (   NEW.role        IS DISTINCT FROM OLD.role
          OR NEW.badgenumber IS DISTINCT FROM OLD.badgenumber
          OR NEW.email       IS DISTINCT FROM OLD.email
          OR NEW.authid      IS DISTINCT FROM OLD.authid
          OR NEW.userid      IS DISTINCT FROM OLD.userid
          OR NEW.datecreated IS DISTINCT FROM OLD.datecreated)
  THEN
    RAISE EXCEPTION 'Only admins can change role, badge number, email or account links';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER protect_user_columns
  BEFORE UPDATE ON public."User"
  FOR EACH ROW EXECUTE FUNCTION public.protect_user_columns();


-- ---------------------------------------------------------------------
-- 5. Tighten table privileges
--    anon (not logged in) gets nothing; sign-up/login go through the
--    Auth API, not through tables. TRUNCATE ignores RLS, so remove it.
-- ---------------------------------------------------------------------
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon;
REVOKE TRUNCATE, TRIGGER, REFERENCES ON ALL TABLES IN SCHEMA public FROM authenticated;

-- Profile rows are only created by the sign-up trigger / removed via auth
REVOKE INSERT, DELETE ON public."User" FROM authenticated;


-- ---------------------------------------------------------------------
-- 6. Policies
--    (select auth.uid()) / (select fn()) wrapping lets Postgres evaluate
--    the call once per query instead of once per row.
-- ---------------------------------------------------------------------

-- ---- User --------------------------------------------------------------
CREATE POLICY "user_select" ON public."User"
  FOR SELECT TO authenticated
  USING (
       authid = (SELECT auth.uid())
    OR (SELECT public.current_user_role()) = 'admin'
    -- investigators can see fellow investigators (collaboration)
    OR ((SELECT public.current_user_role()) = 'investigator' AND role = 'investigator')
  );

CREATE POLICY "user_update" ON public."User"
  FOR UPDATE TO authenticated
  USING      (authid = (SELECT auth.uid()) OR (SELECT public.current_user_role()) = 'admin')
  WITH CHECK (authid = (SELECT auth.uid()) OR (SELECT public.current_user_role()) = 'admin');

-- ---- crimescene --------------------------------------------------------
CREATE POLICY "crimescene_select" ON public.crimescene
  FOR SELECT TO authenticated
  USING (
       (SELECT public.current_user_role()) = 'admin'
    OR reportedby = (SELECT public.current_user_id())
    OR public.is_assigned_to(incidentid)
  );

-- Any signed-in user can report an incident, but only as themselves
CREATE POLICY "crimescene_insert" ON public.crimescene
  FOR INSERT TO authenticated
  WITH CHECK (reportedby = (SELECT public.current_user_id()));

-- Admins, and investigators on the case (e.g. updating status)
CREATE POLICY "crimescene_update" ON public.crimescene
  FOR UPDATE TO authenticated
  USING      ((SELECT public.current_user_role()) = 'admin' OR public.is_assigned_to(incidentid))
  WITH CHECK ((SELECT public.current_user_role()) = 'admin' OR public.is_assigned_to(incidentid));

CREATE POLICY "crimescene_delete" ON public.crimescene
  FOR DELETE TO authenticated
  USING ((SELECT public.current_user_role()) = 'admin');

-- ---- media -------------------------------------------------------------
CREATE POLICY "media_select" ON public.media
  FOR SELECT TO authenticated
  USING (
       (SELECT public.current_user_role()) = 'admin'
    OR uploadedby = (SELECT public.current_user_id())
    OR public.is_assigned_to(incidentid)
  );

-- Upload as yourself, to a case you reported, are assigned to, or (admin) any
CREATE POLICY "media_insert" ON public.media
  FOR INSERT TO authenticated
  WITH CHECK (
    uploadedby = (SELECT public.current_user_id())
    AND (
         (SELECT public.current_user_role()) = 'admin'
      OR public.is_assigned_to(incidentid)
      OR EXISTS (
           SELECT 1 FROM public.crimescene cs
           WHERE cs.incidentid = media.incidentid
             AND cs.reportedby = (SELECT public.current_user_id())
         )
    )
  );

CREATE POLICY "media_update" ON public.media
  FOR UPDATE TO authenticated
  USING      ((SELECT public.current_user_role()) = 'admin')
  WITH CHECK ((SELECT public.current_user_role()) = 'admin');

CREATE POLICY "media_delete" ON public.media
  FOR DELETE TO authenticated
  USING ((SELECT public.current_user_role()) = 'admin');

-- ---- detection (written by the Python pipeline via service_role) -------
CREATE POLICY "detection_select" ON public.detection
  FOR SELECT TO authenticated
  USING (public.can_view_detection(detectionid));

-- ---- vehicledetail -----------------------------------------------------
CREATE POLICY "vehicledetail_select" ON public.vehicledetail
  FOR SELECT TO authenticated
  USING (public.can_view_detection(detectionid));

-- Investigators on the case may correct plate/make/model etc.
CREATE POLICY "vehicledetail_update" ON public.vehicledetail
  FOR UPDATE TO authenticated
  USING      (public.can_view_detection(detectionid))
  WITH CHECK (public.can_view_detection(detectionid));

-- ---- suspect (admin-confirmed only, per the ERD) -----------------------
CREATE POLICY "suspect_select" ON public.suspect
  FOR SELECT TO authenticated
  USING ((SELECT public.current_user_role()) = 'admin' OR public.is_assigned_to(incidentid));

CREATE POLICY "suspect_insert" ON public.suspect
  FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT public.current_user_role()) = 'admin'
    AND (confirmedby IS NULL OR confirmedby = (SELECT public.current_user_id()))
  );

CREATE POLICY "suspect_update" ON public.suspect
  FOR UPDATE TO authenticated
  USING      ((SELECT public.current_user_role()) = 'admin')
  WITH CHECK ((SELECT public.current_user_role()) = 'admin');

CREATE POLICY "suspect_delete" ON public.suspect
  FOR DELETE TO authenticated
  USING ((SELECT public.current_user_role()) = 'admin');

-- ---- correctionlog (append-only audit trail) ---------------------------
CREATE POLICY "correctionlog_select" ON public.correctionlog
  FOR SELECT TO authenticated
  USING (public.can_view_detection(detectionid));

CREATE POLICY "correctionlog_insert" ON public.correctionlog
  FOR INSERT TO authenticated
  WITH CHECK (
    correctedby = (SELECT public.current_user_id())
    AND public.can_view_detection(detectionid)
  );

-- ---- caseassignment ----------------------------------------------------
CREATE POLICY "caseassignment_select" ON public.caseassignment
  FOR SELECT TO authenticated
  USING (
       (SELECT public.current_user_role()) = 'admin'
    OR assignedto = (SELECT public.current_user_id())
  );

CREATE POLICY "caseassignment_insert" ON public.caseassignment
  FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT public.current_user_role()) = 'admin'
    AND assignedby = (SELECT public.current_user_id())
  );

CREATE POLICY "caseassignment_update" ON public.caseassignment
  FOR UPDATE TO authenticated
  USING      ((SELECT public.current_user_role()) = 'admin')
  WITH CHECK ((SELECT public.current_user_role()) = 'admin');

CREATE POLICY "caseassignment_delete" ON public.caseassignment
  FOR DELETE TO authenticated
  USING ((SELECT public.current_user_role()) = 'admin');

-- ---- crossreferencelink (cross-incident analysis) ----------------------
CREATE POLICY "crossref_select" ON public.crossreferencelink
  FOR SELECT TO authenticated
  USING ((SELECT public.current_user_role()) IN ('admin', 'investigator'));

CREATE POLICY "crossref_insert" ON public.crossreferencelink
  FOR INSERT TO authenticated
  WITH CHECK (
    (SELECT public.current_user_role()) IN ('admin', 'investigator')
    AND linkedby = (SELECT public.current_user_id())
  );

CREATE POLICY "crossref_update" ON public.crossreferencelink
  FOR UPDATE TO authenticated
  USING      ((SELECT public.current_user_role()) IN ('admin', 'investigator'))
  WITH CHECK ((SELECT public.current_user_role()) IN ('admin', 'investigator'));

CREATE POLICY "crossref_delete" ON public.crossreferencelink
  FOR DELETE TO authenticated
  USING ((SELECT public.current_user_role()) = 'admin');


-- ---------------------------------------------------------------------
-- 7. Indexes for the FK columns the policies/joins use
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_caseassignment_assignedby ON public.caseassignment (assignedby);
CREATE INDEX IF NOT EXISTS idx_correctionlog_correctedby ON public.correctionlog (correctedby);
CREATE INDEX IF NOT EXISTS idx_crossref_linkedby         ON public.crossreferencelink (linkedby);
CREATE INDEX IF NOT EXISTS idx_suspect_confirmedby       ON public.suspect (confirmedby);