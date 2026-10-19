-- ============================================================================
-- Contact messages from the public website (web/landing "Contact" form)
-- ============================================================================
--
-- Anyone visiting the website can send a message; only the ROOT admin can
-- read them, in the web admin console (Messages).
--
--   submit_contact_message(...)        anon + logged in: saves one message
--   list_contact_messages(status)      root admin only
--   set_contact_message_status(id, s)  root admin only: new / read / replied / archived
--
-- The table itself is closed (RLS on, no policies, no grants): the website
-- can only write through submit_contact_message, which checks every field
-- and limits how often messages can be sent, so the form can't be used to
-- flood the database.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.contactmessage (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name         text NOT NULL CHECK (char_length(name) BETWEEN 2 AND 120),
  email        text NOT NULL CHECK (char_length(email) <= 254
                                    AND email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
  organisation text CHECK (organisation IS NULL OR char_length(organisation) <= 150),
  role         text NOT NULL CHECK (role IN ('Police station', 'CIT security company',
                                             'Investigator', 'Citizen', 'Other')),
  message      text CHECK (message IS NULL OR char_length(message) <= 2000),
  status       text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'read', 'replied', 'archived')),
  datecreated  timestamptz NOT NULL DEFAULT now(),
  handledat    timestamptz,
  handledby    integer REFERENCES public."User"(userid) ON DELETE SET NULL,
  -- md5 of the sender's IP address, only to limit how often one visitor
  -- can send (the address itself is never stored)
  senderhash   text
);

CREATE INDEX IF NOT EXISTS contactmessage_datecreated_idx ON public.contactmessage (datecreated DESC);
CREATE INDEX IF NOT EXISTS contactmessage_email_idx       ON public.contactmessage (lower(email), datecreated);
CREATE INDEX IF NOT EXISTS contactmessage_sender_idx      ON public.contactmessage (senderhash, datecreated);

ALTER TABLE public.contactmessage ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.contactmessage FROM PUBLIC, anon, authenticated;
GRANT  ALL ON public.contactmessage TO service_role;

-- ---------------------------------------------------------------------------
-- The website's form calls this (with the publishable key, no login).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_contact_message(
  p_name         text,
  p_email        text,
  p_role         text,
  p_organisation text DEFAULT NULL,
  p_message      text DEFAULT NULL
)
  RETURNS bigint
  LANGUAGE plpgsql
  VOLATILE SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_name    text := btrim(coalesce(p_name, ''));
  v_email   text := lower(btrim(coalesce(p_email, '')));
  v_role    text := btrim(coalesce(p_role, ''));
  v_org     text := nullif(btrim(coalesce(p_organisation, '')), '');
  v_message text := nullif(btrim(coalesce(p_message, '')), '');
  v_ip      text;
  v_hash    text;
  v_id      bigint;
BEGIN
  IF char_length(v_name) < 2 OR char_length(v_name) > 120 THEN
    RAISE EXCEPTION 'Please enter your name.' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_email) > 254 OR v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' THEN
    RAISE EXCEPTION 'Please enter a valid email address.' USING ERRCODE = '22023';
  END IF;
  IF v_role NOT IN ('Police station', 'CIT security company', 'Investigator', 'Citizen', 'Other') THEN
    RAISE EXCEPTION 'Please choose who you are.' USING ERRCODE = '22023';
  END IF;
  IF v_org IS NOT NULL AND char_length(v_org) > 150 THEN
    RAISE EXCEPTION 'The station or company name is too long.' USING ERRCODE = '22023';
  END IF;
  IF v_message IS NOT NULL AND char_length(v_message) > 2000 THEN
    RAISE EXCEPTION 'Please keep your message under 2000 characters.' USING ERRCODE = '22023';
  END IF;

  -- The visitor's address as PostgREST passes it on (first hop of
  -- x-forwarded-for), hashed. Absent outside PostgREST (tests, SQL editor).
  BEGIN
    v_ip := split_part(
      coalesce(current_setting('request.headers', true), '{}')::json ->> 'x-forwarded-for', ',', 1);
  EXCEPTION WHEN others THEN
    v_ip := NULL;
  END;
  v_hash := CASE WHEN nullif(btrim(v_ip), '') IS NULL THEN NULL ELSE md5('argus-contact:' || btrim(v_ip)) END;

  -- Limits: 3 an hour from one email address, 5 an hour from one visitor,
  -- 60 an hour from everybody together (stops a script flooding the table).
  IF (SELECT count(*) FROM public.contactmessage
      WHERE lower(email) = v_email AND datecreated > now() - interval '1 hour') >= 3
     OR (v_hash IS NOT NULL AND
         (SELECT count(*) FROM public.contactmessage
          WHERE senderhash = v_hash AND datecreated > now() - interval '1 hour') >= 5)
     OR (SELECT count(*) FROM public.contactmessage
         WHERE datecreated > now() - interval '1 hour') >= 60 THEN
    RAISE EXCEPTION 'Too many messages right now. Please try again in an hour.' USING ERRCODE = '54000';
  END IF;

  INSERT INTO public.contactmessage (name, email, organisation, role, message, senderhash)
  VALUES (v_name, v_email, v_org, v_role, v_message, v_hash)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- Root admin: read the messages (newest first) and mark them.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_contact_messages(p_status text DEFAULT NULL)
  RETURNS TABLE (
    id            bigint,
    name          text,
    email         text,
    organisation  text,
    role          text,
    message       text,
    status        text,
    datecreated   timestamptz,
    handledat     timestamptz,
    handledby_name text
  )
  LANGUAGE plpgsql
  STABLE SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_root_admin() THEN
    RAISE EXCEPTION 'Only the root administrator can read website messages.' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT m.id, m.name, m.email, m.organisation, m.role, m.message, m.status,
           m.datecreated, m.handledat,
           nullif(btrim(coalesce(u.firstname, '') || ' ' || coalesce(u.surname, '')), '')
    FROM public.contactmessage m
    LEFT JOIN public."User" u ON u.userid = m.handledby
    WHERE p_status IS NULL OR m.status = p_status
    ORDER BY m.datecreated DESC
    LIMIT 500;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_contact_message_status(p_id bigint, p_status text)
  RETURNS void
  LANGUAGE plpgsql
  VOLATILE SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_root_admin() THEN
    RAISE EXCEPTION 'Only the root administrator can update website messages.' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('new', 'read', 'replied', 'archived') THEN
    RAISE EXCEPTION 'Unknown status %.', p_status USING ERRCODE = '22023';
  END IF;
  UPDATE public.contactmessage
     SET status    = p_status,
         handledat = CASE WHEN p_status = 'new' THEN NULL ELSE now() END,
         handledby = CASE WHEN p_status = 'new' THEN NULL ELSE public.current_user_id() END
   WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Message % not found.', p_id USING ERRCODE = 'P0002';
  END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.submit_contact_message(text, text, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.list_contact_messages(text)                         FROM PUBLIC, anon;
REVOKE EXECUTE ON FUNCTION public.set_contact_message_status(bigint, text)           FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.submit_contact_message(text, text, text, text, text) TO anon, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.list_contact_messages(text)                         TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.set_contact_message_status(bigint, text)           TO authenticated, service_role;
