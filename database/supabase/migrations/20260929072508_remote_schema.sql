SET local check_function_bodies = off;

CREATE SEQUENCE "public"."User_userid_seq" AS integer INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1 CACHE 1 NO CYCLE;

CREATE SEQUENCE "public"."caseassignment_assignmentid_seq" AS integer INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1 CACHE 1 NO CYCLE;

CREATE SEQUENCE "public"."correctionlog_correctionid_seq" AS integer INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1 CACHE 1 NO CYCLE;

CREATE SEQUENCE "public"."crimescene_incidentid_seq" AS integer INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1 CACHE 1 NO CYCLE;

CREATE SEQUENCE "public"."crossreferencelink_linkid_seq" AS integer INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1 CACHE 1 NO CYCLE;

CREATE SEQUENCE "public"."detection_detectionid_seq" AS integer INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1 CACHE 1 NO CYCLE;

CREATE SEQUENCE "public"."media_mediaid_seq" AS integer INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1 CACHE 1 NO CYCLE;

CREATE SEQUENCE "public"."suspect_suspectid_seq" AS integer INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1 CACHE 1 NO CYCLE;

CREATE SEQUENCE "public"."vehicledetail_vehicledetectionid_seq" AS integer INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1 CACHE 1 NO CYCLE;

CREATE TABLE "public"."User" (
  "userid"       integer                  NOT NULL DEFAULT nextval('public."User_userid_seq"'::regclass),
  "fullname"     character varying(100)   NOT NULL,
  "email"        character varying(150)   NOT NULL,
  "passwordhash" text                     NOT NULL,
  "role"         character varying(50)    NOT NULL,
  "badgenumber"  character varying(50),
  "datecreated"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "User_badgenumber_key" UNIQUE (badgenumber),
  CONSTRAINT "User_email_key" UNIQUE (email),
  CONSTRAINT "User_pkey" PRIMARY KEY (userid),
  CONSTRAINT "User_role_check" CHECK (((role)::text = ANY ((ARRAY['admin'::character varying, 'investigator'::character varying, 'citizen'::character varying])::text[])))
);

ALTER TABLE "public"."User"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."caseassignment" (
  "assignmentid"     integer                  NOT NULL DEFAULT nextval('public.caseassignment_assignmentid_seq'::regclass),
  "incidentid"       integer                  NOT NULL,
  "assignedto"       integer                  NOT NULL,
  "assignedby"       integer                  NOT NULL,
  "assignmentstatus" character varying(50)    NOT NULL DEFAULT 'active'::character varying,
  "dateassigned"     timestamp with time zone NOT NULL DEFAULT now(),
  "dateunassigned"   timestamp with time zone,
  CONSTRAINT "caseassignment_assignmentstatus_check"
    CHECK (((assignmentstatus)::text = ANY ((ARRAY['active'::character varying, 'reassigned'::character varying, 'closed'::character varying])::text[]))),
  CONSTRAINT "caseassignment_pkey" PRIMARY KEY (assignmentid)
);

ALTER TABLE "public"."caseassignment"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."correctionlog" (
  "correctionid"        integer                  NOT NULL DEFAULT nextval('public.correctionlog_correctionid_seq'::regclass),
  "detectionid"         integer                  NOT NULL,
  "correctedby"         integer                  NOT NULL,
  "originalvalue"       text                     NOT NULL,
  "correctedvalue"      text                     NOT NULL,
  "correctiontimestamp" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "correctionlog_pkey" PRIMARY KEY (correctionid)
);

ALTER TABLE "public"."correctionlog"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."crimescene" (
  "incidentid"  integer                  NOT NULL DEFAULT nextval('public.crimescene_incidentid_seq'::regclass),
  "location"    text                     NOT NULL,
  "datetime"    timestamp with time zone NOT NULL,
  "attacktype"  character varying(100),
  "status"      character varying(50)    NOT NULL DEFAULT 'open'::character varying,
  "description" text,
  "reportedby"  integer                  NOT NULL,
  CONSTRAINT "crimescene_pkey" PRIMARY KEY (incidentid),
  CONSTRAINT "crimescene_status_check" CHECK (((status)::text = ANY ((ARRAY['open'::character varying, 'closed'::character varying, 'under_review'::character varying])::text[])))
);

ALTER TABLE "public"."crimescene"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."crossreferencelink" (
  "linkid"             integer                  NOT NULL DEFAULT nextval('public.crossreferencelink_linkid_seq'::regclass),
  "entitytype"         character varying(50)    NOT NULL,
  "entityid_a"         integer                  NOT NULL,
  "entityid_b"         integer                  NOT NULL,
  "matchconfidence"    numeric(5,4),
  "linkedby"           integer                  NOT NULL,
  "verificationstatus" character varying(50)    NOT NULL DEFAULT 'pending'::character varying,
  "datelinked"         timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "crossreferencelink_check" CHECK ((entityid_a <> entityid_b)),
  CONSTRAINT "crossreferencelink_entitytype_check" CHECK (((entitytype)::text = ANY ((ARRAY['vehicle'::character varying, 'suspect'::character varying])::text[]))),
  CONSTRAINT "crossreferencelink_matchconfidence_check" CHECK (((matchconfidence >= (0)::numeric) AND (matchconfidence <= (1)::numeric))),
  CONSTRAINT "crossreferencelink_pkey" PRIMARY KEY (linkid),
  CONSTRAINT "crossreferencelink_verificationstatus_check"
    CHECK (((verificationstatus)::text = ANY ((ARRAY['pending'::character varying, 'verified'::character varying, 'rejected'::character varying])::text[])))
);

ALTER TABLE "public"."crossreferencelink"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."detection" (
  "detectionid"     integer               NOT NULL DEFAULT nextval('public.detection_detectionid_seq'::regclass),
  "mediaid"         integer               NOT NULL,
  "detectiontype"   character varying(50) NOT NULL,
  "frametimestamp"  numeric(10,3),
  "boundingbox"     jsonb,
  "confidencescore" numeric(5,4),
  "modelversion"    character varying(50),
  CONSTRAINT "detection_confidencescore_check" CHECK (((confidencescore >= (0)::numeric) AND (confidencescore <= (1)::numeric))),
  CONSTRAINT "detection_detectiontype_check"
    CHECK (((detectiontype)::text = ANY ((ARRAY['vehicle'::character varying, 'person'::character varying, 'weapon'::character varying])::text[]))),
  CONSTRAINT "detection_pkey" PRIMARY KEY (detectionid)
);

ALTER TABLE "public"."detection"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."media" (
  "mediaid"          integer                  NOT NULL DEFAULT nextval('public.media_mediaid_seq'::regclass),
  "incidentid"       integer                  NOT NULL,
  "uploadedby"       integer                  NOT NULL,
  "mediatype"        character varying(50)    NOT NULL,
  "storagepath"      text                     NOT NULL,
  "filehash"         character varying(256),
  "filesize"         bigint,
  "capturetimestamp" timestamp with time zone,
  "uploadtimestamp"  timestamp with time zone NOT NULL DEFAULT now(),
  "processingstatus" character varying(50)    NOT NULL DEFAULT 'pending'::character varying,
  "isencrypted"      boolean                  NOT NULL DEFAULT false,
  CONSTRAINT "media_mediatype_check" CHECK (((mediatype)::text = ANY ((ARRAY['image'::character varying, 'video'::character varying, 'audio'::character varying])::text[]))),
  CONSTRAINT "media_pkey" PRIMARY KEY (mediaid),
  CONSTRAINT "media_processingstatus_check"
    CHECK
    (((processingstatus)::text = ANY ((ARRAY['pending'::character varying, 'processing'::character varying, 'completed'::character varying, 'failed'::character varying])::text[])))
);

ALTER TABLE "public"."media"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."suspect" (
  "suspectid"             integer                  NOT NULL DEFAULT nextval('public.suspect_suspectid_seq'::regclass),
  "detectionid"           integer                  NOT NULL,
  "incidentid"            integer                  NOT NULL,
  "physicaldescription"   text,
  "clothingdescription"   text,
  "behaviouralindicators" text,
  "confirmedby"           integer,
  "dateconfirmed"         timestamp with time zone,
  CONSTRAINT "suspect_detectionid_key" UNIQUE (detectionid),
  CONSTRAINT "suspect_pkey" PRIMARY KEY (suspectid)
);

ALTER TABLE "public"."suspect"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."vehicledetail" (
  "vehicledetectionid" integer                NOT NULL DEFAULT nextval('public.vehicledetail_vehicledetectionid_seq'::regclass),
  "detectionid"        integer                NOT NULL,
  "vehicletype"        character varying(50),
  "make"               character varying(100),
  "model"              character varying(100),
  "colour"             character varying(50),
  "platedetected"      boolean                NOT NULL DEFAULT false,
  "licenceplatenumber" character varying(20),
  "plateconfidence"    numeric(5,4),
  "plateobscured"      boolean                NOT NULL DEFAULT false,
  CONSTRAINT "vehicledetail_detectionid_key" UNIQUE (detectionid),
  CONSTRAINT "vehicledetail_pkey" PRIMARY KEY (vehicledetectionid),
  CONSTRAINT "vehicledetail_plateconfidence_check" CHECK (((plateconfidence >= (0)::numeric) AND (plateconfidence <= (1)::numeric)))
);

ALTER TABLE "public"."vehicledetail"
  ENABLE ROW LEVEL SECURITY;

ALTER SEQUENCE "public"."User_userid_seq" OWNED BY "public"."User"."userid";

ALTER SEQUENCE "public"."caseassignment_assignmentid_seq" OWNED BY "public"."caseassignment"."assignmentid";

ALTER SEQUENCE "public"."correctionlog_correctionid_seq" OWNED BY "public"."correctionlog"."correctionid";

ALTER SEQUENCE "public"."crimescene_incidentid_seq" OWNED BY "public"."crimescene"."incidentid";

ALTER SEQUENCE "public"."crossreferencelink_linkid_seq" OWNED BY "public"."crossreferencelink"."linkid";

ALTER SEQUENCE "public"."detection_detectionid_seq" OWNED BY "public"."detection"."detectionid";

ALTER SEQUENCE "public"."media_mediaid_seq" OWNED BY "public"."media"."mediaid";

ALTER SEQUENCE "public"."suspect_suspectid_seq" OWNED BY "public"."suspect"."suspectid";

ALTER SEQUENCE "public"."vehicledetail_vehicledetectionid_seq" OWNED BY "public"."vehicledetail"."vehicledetectionid";

CREATE OR REPLACE FUNCTION public.rls_auto_enable()
  RETURNS event_trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'pg_catalog'
  AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

ALTER TABLE "public"."caseassignment"
  ADD CONSTRAINT "caseassignment_assignedby_fkey" FOREIGN KEY (assignedby) REFERENCES public."User"(userid);

ALTER TABLE "public"."caseassignment"
  ADD CONSTRAINT "caseassignment_assignedto_fkey" FOREIGN KEY (assignedto) REFERENCES public."User"(userid);

ALTER TABLE "public"."correctionlog"
  ADD CONSTRAINT "correctionlog_correctedby_fkey" FOREIGN KEY (correctedby) REFERENCES public."User"(userid);

ALTER TABLE "public"."caseassignment"
  ADD CONSTRAINT "caseassignment_incidentid_fkey" FOREIGN KEY (incidentid) REFERENCES public.crimescene(incidentid);

ALTER TABLE "public"."crimescene"
  ADD CONSTRAINT "crimescene_reportedby_fkey" FOREIGN KEY (reportedby) REFERENCES public."User"(userid);

ALTER TABLE "public"."crossreferencelink"
  ADD CONSTRAINT "crossreferencelink_linkedby_fkey" FOREIGN KEY (linkedby) REFERENCES public."User"(userid);

ALTER TABLE "public"."correctionlog"
  ADD CONSTRAINT "correctionlog_detectionid_fkey" FOREIGN KEY (detectionid) REFERENCES public.detection(detectionid);

ALTER TABLE "public"."media"
  ADD CONSTRAINT "media_incidentid_fkey" FOREIGN KEY (incidentid) REFERENCES public.crimescene(incidentid);

ALTER TABLE "public"."detection"
  ADD CONSTRAINT "detection_mediaid_fkey" FOREIGN KEY (mediaid) REFERENCES public.media(mediaid);

ALTER TABLE "public"."media"
  ADD CONSTRAINT "media_uploadedby_fkey" FOREIGN KEY (uploadedby) REFERENCES public."User"(userid);

ALTER TABLE "public"."suspect"
  ADD CONSTRAINT "suspect_confirmedby_fkey" FOREIGN KEY (confirmedby) REFERENCES public."User"(userid);

ALTER TABLE "public"."suspect"
  ADD CONSTRAINT "suspect_detectionid_fkey" FOREIGN KEY (detectionid) REFERENCES public.detection(detectionid);

ALTER TABLE "public"."suspect"
  ADD CONSTRAINT "suspect_incidentid_fkey" FOREIGN KEY (incidentid) REFERENCES public.crimescene(incidentid);

ALTER TABLE "public"."vehicledetail"
  ADD CONSTRAINT "vehicledetail_detectionid_fkey" FOREIGN KEY (detectionid) REFERENCES public.detection(detectionid);

CREATE INDEX idx_caseassignment_assignedto ON public.caseassignment USING btree (assignedto);

CREATE INDEX idx_caseassignment_incidentid ON public.caseassignment USING btree (incidentid);

CREATE INDEX idx_correctionlog_detectionid ON public.correctionlog USING btree (detectionid);

CREATE INDEX idx_crimescene_reportedby ON public.crimescene USING btree (reportedby);

CREATE INDEX idx_crossref_entity_a ON public.crossreferencelink USING btree (entitytype, entityid_a);

CREATE INDEX idx_crossref_entity_b ON public.crossreferencelink USING btree (entitytype, entityid_b);

CREATE INDEX idx_detection_mediaid ON public.detection USING btree (mediaid);

CREATE INDEX idx_detection_type ON public.detection USING btree (detectiontype);

CREATE INDEX idx_media_incidentid ON public.media USING btree (incidentid);

CREATE INDEX idx_media_processingstatus ON public.media USING btree (processingstatus);

CREATE INDEX idx_media_uploadedby ON public.media USING btree (uploadedby);

CREATE INDEX idx_suspect_detectionid ON public.suspect USING btree (detectionid);

CREATE INDEX idx_suspect_incidentid ON public.suspect USING btree (incidentid);

CREATE INDEX idx_vehicledetail_detectionid ON public.vehicledetail USING btree (detectionid);

CREATE EVENT TRIGGER "ensure_rls"
  ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  EXECUTE FUNCTION "public"."rls_auto_enable"();

GRANT EXECUTE ON FUNCTION "public"."rls_auto_enable"() TO PUBLIC, "anon", "authenticated", "postgres", "service_role";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."User_userid_seq" TO "anon", "authenticated", "postgres", "service_role";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."caseassignment_assignmentid_seq" TO "anon", "authenticated", "postgres", "service_role";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."correctionlog_correctionid_seq" TO "anon", "authenticated", "postgres", "service_role";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."crimescene_incidentid_seq" TO "anon", "authenticated", "postgres", "service_role";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."crossreferencelink_linkid_seq" TO "anon", "authenticated", "postgres", "service_role";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."detection_detectionid_seq" TO "anon", "authenticated", "postgres", "service_role";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."media_mediaid_seq" TO "anon", "authenticated", "postgres", "service_role";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."suspect_suspectid_seq" TO "anon", "authenticated", "postgres", "service_role";

GRANT SELECT, UPDATE, USAGE ON SEQUENCE "public"."vehicledetail_vehicledetectionid_seq" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."User" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."caseassignment" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."correctionlog" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."crimescene" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."crossreferencelink" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."detection" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."media" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."suspect" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."vehicledetail" TO "anon", "authenticated", "postgres", "service_role";

