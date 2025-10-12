CREATE SCHEMA IF NOT EXISTS "admin";

CREATE SCHEMA IF NOT EXISTS "extensions";

DROP EXTENSION IF EXISTS http;

CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;

CREATE EXTENSION IF NOT EXISTS pg_tle;

CREATE EXTENSION IF NOT EXISTS "btree_gist" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "ltree";

CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgtap" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "plpgsql_check" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE EXTENSION IF NOT EXISTS "vector";

DO $do$
BEGIN
    IF EXISTS (
        SELECT
        FROM
            pg_catalog.pg_roles
        WHERE
            rolname = 'internal_admin') THEN
    RAISE NOTICE 'Role "internal_admin" already exists. Skipping.';
ELSE
    CREATE ROLE internal_admin WITH LOGIN;
END IF;
END
$do$;

GRANT ALL privileges ON ALL TABLES IN SCHEMA public TO internal_admin;

CREATE OR REPLACE FUNCTION gen_random_uuid_v7 ()
    RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_time timestamp with time zone := NULL;
    v_secs bigint := NULL;
    v_msec bigint := NULL;
    v_usec bigint := NULL;
    v_timestamp bigint := NULL;
    v_timestamp_hex varchar := NULL;
    v_random bigint := NULL;
    v_random_hex varchar := NULL;
    v_bytes bytea;
    c_variant bit(64) := x'8000000000000000';
    -- RFC-4122 variant: b'10xx...'
BEGIN
    -- Get seconds and micros
    v_time := clock_timestamp();
    v_secs := EXTRACT(EPOCH FROM v_time);
    v_msec := mod(EXTRACT(MILLISECONDS FROM v_time)::numeric, 10 ^ 3::numeric);
    v_usec := mod(EXTRACT(MICROSECONDS FROM v_time)::numeric, 10 ^ 3::numeric);
    -- Generate timestamp hexadecimal (and set version 7)
    v_timestamp := (((v_secs * 10 ^ 3) + v_msec)::bigint << 12) | (v_usec << 2);
    v_timestamp_hex := lpad(to_hex(v_timestamp), 16, '0');
    v_timestamp_hex := substr(v_timestamp_hex, 2, 12) || '7' || substr(v_timestamp_hex, 14, 3);
    -- Generate the random hexadecimal (and set variant b'10xx')
    v_random := ((random()::numeric * 2 ^ 62::numeric)::bigint::bit(64) | c_variant)::bigint;
    v_random_hex := lpad(to_hex(v_random), 16, '0');
    -- Concat timestemp and random hexadecimal
    v_bytes := decode(v_timestamp_hex || v_random_hex, 'hex');
    RETURN encode(v_bytes, 'hex')::uuid;
END
$$;

CREATE TYPE "public"."activity_type" AS enum (
    'task',
    'event',
    'note'
);

CREATE TYPE "public"."agent_environment" AS enum (
    'test',
    'private',
    'review',
    'public'
);

CREATE TYPE "public"."tag_type" AS enum (
    'toggle',
    'count',
    'compute'
);

CREATE OR REPLACE FUNCTION public.generate_path (parent ltree DEFAULT NULL::LTREE)
    RETURNS ltree
    LANGUAGE plpgsql
    AS $function$
DECLARE
    characters text := 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    random_path text := '';
    prefix text := '';
    random_int integer;
    len integer;
BEGIN
    IF parent IS NOT NULL THEN
        prefix := ltree2text (parent) || '.';
        len := 4;
    ELSE
        len := 12;
    END IF;
    FOR i IN 1..len LOOP
        random_int := floor(random() * length(characters))::integer + 1;
        random_path := random_path || substr(characters, random_int, 1);
    END LOOP;
    RETURN text2ltree (prefix || random_path);
END;
$function$;

CREATE OR REPLACE FUNCTION public.order_first ()
    RETURNS double precision
    LANGUAGE plpgsql
    AS $function$
DECLARE
    millis_since_epoch double precision;
BEGIN
    millis_since_epoch := EXTRACT(epoch FROM CURRENT_TIMESTAMP) * 1000;
    RETURN millis_since_epoch;
END;
$function$;

CREATE TABLE "public"."activity" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "author_id" uuid NOT NULL,
    "assignee_id" uuid,
    "updated_by" integer NOT NULL DEFAULT 0,
    "deleted_at" timestamp with time zone,
    "priority_id" uuid NOT NULL,
    "type" activity_type NOT NULL DEFAULT 'note' ::activity_type,
    "path" ltree NOT NULL DEFAULT generate_path (NULL::LTREE),
    "order" double precision NOT NULL DEFAULT order_first (),
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "title" text,
    "note" text,
    "links" jsonb,
    "at" tstzrange,
    "on" daterange,
    "duration" interval,
    "done_at" timestamp with time zone,
    "recurrence_rule" text,
    "recurrence_exdates" timestamp with time zone[],
    "recurrence_dates" timestamp with time zone[],
    "source" jsonb
);

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."activity_exception" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_by" integer NOT NULL DEFAULT 0,
    "deleted_at" timestamp with time zone,
    "activity_id" uuid NOT NULL,
    "occurrence" text NOT NULL,
    "at" tstzrange,
    "on" daterange,
    "duration" interval,
    "done_at" timestamp with time zone,
    "title" text,
    "note" text,
    "source" jsonb
);

ALTER TABLE "public"."activity_exception" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."activity_tag" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "actor_id" uuid NOT NULL,
    "activity_id" uuid NOT NULL,
    "occurrence" text,
    "tag_id" integer NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0
);

ALTER TABLE "public"."activity_tag" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."agent" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "root_id" uuid NOT NULL,
    "name" text NOT NULL,
    "description" text NOT NULL,
    "author_id" bigint NOT NULL,
    "version" text NOT NULL,
    "environment" agent_environment NOT NULL DEFAULT 'test' ::agent_environment
);

ALTER TABLE "public"."agent" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."agent_access" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "agent_id" uuid NOT NULL,
    "priority_membership_id" uuid NOT NULL,
    "priority_access_id" uuid
);

ALTER TABLE "public"."agent_access" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."agent_author" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL,
    "email" text,
    "url" text
);

ALTER TABLE "public"."agent_author" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."agent_token" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "agent_id" uuid,
    "token" text NOT NULL,
    "priority_id" uuid
);

ALTER TABLE "public"."agent_token" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."contact" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "email" text NOT NULL,
    "name" text,
    "avatar_url" text,
    "user_id" uuid
);

ALTER TABLE "public"."contact" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."domain" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL,
    "organization_id" bigint
);

ALTER TABLE "public"."domain" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."invitation" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "code" text NOT NULL,
    "remaining" numeric NOT NULL DEFAULT '1' ::numeric
);

ALTER TABLE "public"."invitation" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."organization" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL
);

ALTER TABLE "public"."organization" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL,
    "root" boolean NOT NULL DEFAULT FALSE,
    "deleted_at" timestamp with time zone,
    "title" text NOT NULL,
    "path" ltree NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0
);

ALTER TABLE "public"."priority" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority_agent" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "priority_id" uuid NOT NULL,
    "agent_id" uuid NOT NULL,
    "owner_id" uuid NOT NULL,
    "name" text NOT NULL,
    "config" jsonb NOT NULL DEFAULT '{}' ::jsonb,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone
);

ALTER TABLE "public"."priority_agent" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority_contact" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "priority_id" uuid NOT NULL,
    "contact_id" uuid NOT NULL
);

ALTER TABLE "public"."priority_contact" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority_settings" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "priority_id" uuid NOT NULL,
    "top_order" double precision,
    "path" ltree,
    "pomodoro" integer,
    "color" integer
);

ALTER TABLE "public"."priority_settings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority_user" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "priority_id" uuid NOT NULL,
    "deleted_at" timestamp with time zone
);

ALTER TABLE "public"."priority_user" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."series" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "series" text NOT NULL,
    "invitees" text[],
    "embedding" vector (384),
    "priority_id" uuid
);

ALTER TABLE "public"."series" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."session" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "user_id" uuid NOT NULL,
    "priority_id" uuid,
    "at" tstzrange NOT NULL,
    "precedence" smallint NOT NULL DEFAULT 0,
    "pomodoro" smallint,
    "pomodoro_at" timestamp with time zone,
    "updated_by" integer NOT NULL DEFAULT 0
);

ALTER TABLE "public"."session" ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX activity_exception_pkey ON public.activity_exception USING btree (id);

CREATE UNIQUE INDEX activity_pkey ON public.activity USING btree (id);

CREATE INDEX activity_tag_activity_id_tag_id_idx ON public.activity_tag USING btree (activity_id, tag_id)
WHERE (deleted_at IS NULL);

CREATE UNIQUE INDEX activity_tag_actor_id_activity_id_tag_id_key ON public.activity_tag USING btree (actor_id, activity_id, tag_id);

CREATE UNIQUE INDEX agent_access_unique ON public.agent_access USING btree (agent_id, priority_membership_id);

CREATE UNIQUE INDEX agent_author_pkey ON public.agent_author USING btree (id);

CREATE UNIQUE INDEX agent_pkey ON public.agent USING btree (id);

CREATE UNIQUE INDEX agent_rootid_env_unique_idx ON public.agent USING btree (root_id, environment);

CREATE UNIQUE INDEX agent_token_pkey ON public.agent_token USING btree (token);

CREATE UNIQUE INDEX contact_pkey ON public.contact USING btree (id);

CREATE UNIQUE INDEX contact_user_email_unique ON public.contact USING btree (email);

CREATE UNIQUE INDEX contact_user_id_unique ON public.contact USING btree (user_id);

CREATE UNIQUE INDEX domain_name_key ON public.domain USING btree (name);

CREATE UNIQUE INDEX domain_pkey ON public.domain USING btree (id);

CREATE INDEX idx_activity_at ON public.activity USING gist (at);

CREATE INDEX idx_activity_done_at ON public.activity USING btree (done_at);

CREATE INDEX idx_activity_occurrence ON public.activity_exception USING btree (activity_id, occurrence);

CREATE INDEX idx_activity_on ON public.activity USING gist ("on");

CREATE INDEX idx_activity_path ON public.activity USING gist (path);

CREATE INDEX idx_activity_priority_id ON public.activity USING btree (priority_id);

CREATE INDEX idx_agent_priority_id ON public.priority_agent USING btree (priority_id);

CREATE UNIQUE INDEX idx_priority_created_by_root_true ON public.priority USING btree (created_by)
WHERE (root = TRUE);

CREATE UNIQUE INDEX invitation_code_key ON public.invitation USING btree (code);

CREATE UNIQUE INDEX invitation_pkey ON public.invitation USING btree (id);

CREATE INDEX name ON public.domain USING btree (name);

CREATE UNIQUE INDEX organization_pkey ON public.organization USING btree (id);

CREATE UNIQUE INDEX priority_agent_pkey ON public.priority_agent USING btree (id);

CREATE UNIQUE INDEX priority_contact_pkey ON public.priority_contact USING btree (id);

CREATE UNIQUE INDEX priority_contact_unique ON public.priority_contact USING btree (priority_id, contact_id);

CREATE UNIQUE INDEX priority_path_key ON public.priority USING btree (path);

CREATE UNIQUE INDEX priority_pkey ON public.priority USING btree (id);

CREATE UNIQUE INDEX priority_settings_unique ON public.priority_settings USING btree (user_id, priority_id);

CREATE UNIQUE INDEX priority_user_unique ON public.priority_user USING btree (user_id, priority_id);

CREATE UNIQUE INDEX series_pkey ON public.series USING btree (id);

CREATE UNIQUE INDEX series_unique ON public.series USING btree (user_id, series);

CREATE INDEX session_at_idx ON public.session USING spgist (at);

CREATE UNIQUE INDEX session_pkey ON public.session USING btree (id);

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_pkey" PRIMARY KEY USING INDEX "activity_pkey";

ALTER TABLE "public"."activity_exception"
    ADD CONSTRAINT "activity_exception_pkey" PRIMARY KEY USING INDEX "activity_exception_pkey";

ALTER TABLE "public"."agent"
    ADD CONSTRAINT "agent_pkey" PRIMARY KEY USING INDEX "agent_pkey";

ALTER TABLE "public"."agent_author"
    ADD CONSTRAINT "agent_author_pkey" PRIMARY KEY USING INDEX "agent_author_pkey";

ALTER TABLE "public"."agent_token"
    ADD CONSTRAINT "agent_token_pkey" PRIMARY KEY USING INDEX "agent_token_pkey";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_pkey" PRIMARY KEY USING INDEX "contact_pkey";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_pkey" PRIMARY KEY USING INDEX "domain_pkey";

ALTER TABLE "public"."invitation"
    ADD CONSTRAINT "invitation_pkey" PRIMARY KEY USING INDEX "invitation_pkey";

ALTER TABLE "public"."organization"
    ADD CONSTRAINT "organization_pkey" PRIMARY KEY USING INDEX "organization_pkey";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_pkey" PRIMARY KEY USING INDEX "priority_pkey";

ALTER TABLE "public"."priority_agent"
    ADD CONSTRAINT "priority_agent_pkey" PRIMARY KEY USING INDEX "priority_agent_pkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_pkey" PRIMARY KEY USING INDEX "priority_contact_pkey";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_pkey" PRIMARY KEY USING INDEX "series_pkey";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_pkey" PRIMARY KEY USING INDEX "session_pkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_no_complete_recurrence" CHECK (((recurrence_rule IS NULL) OR (done_at IS NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_no_complete_recurrence";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_priority_id_fkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_recurrence_on_or_at" CHECK (((recurrence_rule IS NULL) OR (at IS NOT NULL) OR ("on" IS NOT NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_recurrence_on_or_at";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_scheduled" CHECK ((((recurrence_rule IS NULL) AND (type <> ALL (ARRAY['task'::activity_type, 'event'::activity_type]))) OR (at IS NOT NULL) OR ("on" IS NOT NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_scheduled";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_single_schedule" CHECK (((at IS NULL) OR ("on" IS NULL))) NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_single_schedule";

ALTER TABLE "public"."activity_exception"
    ADD CONSTRAINT "activity_exception_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) NOT valid;

ALTER TABLE "public"."activity_exception" validate CONSTRAINT "activity_exception_activity_id_fkey";

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_tag" validate CONSTRAINT "activity_tag_activity_id_fkey";

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_actor_id_activity_id_tag_id_key" UNIQUE USING INDEX "activity_tag_actor_id_activity_id_tag_id_key";

ALTER TABLE "public"."agent"
    ADD CONSTRAINT "agent_author_id_fkey" FOREIGN KEY (author_id) REFERENCES agent_author (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."agent" validate CONSTRAINT "agent_author_id_fkey";

ALTER TABLE "public"."agent"
    ADD CONSTRAINT "agent_root_id_fkey" FOREIGN KEY (root_id) REFERENCES agent (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."agent" validate CONSTRAINT "agent_root_id_fkey";

ALTER TABLE "public"."agent"
    ADD CONSTRAINT "id_rootid_not_equal_if_not_test" CHECK (((environment = 'test'::agent_environment) OR (id <> root_id))) NOT valid;

ALTER TABLE "public"."agent" validate CONSTRAINT "id_rootid_not_equal_if_not_test";

ALTER TABLE "public"."agent_access"
    ADD CONSTRAINT "agent_access_agent_id_fkey" FOREIGN KEY (agent_id) REFERENCES agent (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."agent_access" validate CONSTRAINT "agent_access_agent_id_fkey";

ALTER TABLE "public"."agent_access"
    ADD CONSTRAINT "agent_access_priority_access_id_fkey" FOREIGN KEY (priority_access_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."agent_access" validate CONSTRAINT "agent_access_priority_access_id_fkey";

ALTER TABLE "public"."agent_access"
    ADD CONSTRAINT "agent_access_priority_membership_id_fkey" FOREIGN KEY (priority_membership_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."agent_access" validate CONSTRAINT "agent_access_priority_membership_id_fkey";

ALTER TABLE "public"."agent_access"
    ADD CONSTRAINT "agent_access_unique" UNIQUE USING INDEX "agent_access_unique";

ALTER TABLE "public"."agent_token"
    ADD CONSTRAINT "agent_token_agent_id_fkey" FOREIGN KEY (agent_id) REFERENCES agent (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."agent_token" validate CONSTRAINT "agent_token_agent_id_fkey";

ALTER TABLE "public"."agent_token"
    ADD CONSTRAINT "agent_token_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."agent_token" validate CONSTRAINT "agent_token_priority_id_fkey";

CREATE OR REPLACE FUNCTION public.is_lower (text)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN $1 = lower($1);
END;
$function$;

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_email_check" CHECK (is_lower (email)) NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_email_check";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_email_unique" UNIQUE USING INDEX "contact_user_email_unique";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_user_id_fkey";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_id_unique" UNIQUE USING INDEX "contact_user_id_unique";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_name_check" CHECK (is_lower (name)) NOT valid;

ALTER TABLE "public"."domain" validate CONSTRAINT "domain_name_check";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_name_key" UNIQUE USING INDEX "domain_name_key";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES organization (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."domain" validate CONSTRAINT "domain_organization_id_fkey";

ALTER TABLE "public"."invitation"
    ADD CONSTRAINT "invitation_code_key" UNIQUE USING INDEX "invitation_code_key";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority" validate CONSTRAINT "priority_created_by_fkey";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_path_key" UNIQUE USING INDEX "priority_path_key";

ALTER TABLE "public"."priority_agent"
    ADD CONSTRAINT "priority_agent_agent_id_fkey" FOREIGN KEY (agent_id) REFERENCES agent (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_agent" validate CONSTRAINT "priority_agent_agent_id_fkey";

ALTER TABLE "public"."priority_agent"
    ADD CONSTRAINT "priority_agent_owner_id_fkey" FOREIGN KEY (owner_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_agent" validate CONSTRAINT "priority_agent_owner_id_fkey";

ALTER TABLE "public"."priority_agent"
    ADD CONSTRAINT "priority_agent_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_agent" validate CONSTRAINT "priority_agent_priority_id_fkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_contact_id_fkey" FOREIGN KEY (contact_id) REFERENCES contact (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_contact" validate CONSTRAINT "priority_contact_contact_id_fkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_contact" validate CONSTRAINT "priority_contact_priority_id_fkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_unique" UNIQUE USING INDEX "priority_contact_unique";

ALTER TABLE "public"."priority_settings"
    ADD CONSTRAINT "priority_settings_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_settings" validate CONSTRAINT "priority_settings_priority_id_fkey";

ALTER TABLE "public"."priority_settings"
    ADD CONSTRAINT "priority_settings_unique" UNIQUE USING INDEX "priority_settings_unique";

ALTER TABLE "public"."priority_settings"
    ADD CONSTRAINT "priority_settings_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_settings" validate CONSTRAINT "priority_settings_user_id_fkey";

ALTER TABLE "public"."priority_user"
    ADD CONSTRAINT "priority_user_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_user" validate CONSTRAINT "priority_user_priority_id_fkey";

ALTER TABLE "public"."priority_user"
    ADD CONSTRAINT "priority_user_unique" UNIQUE USING INDEX "priority_user_unique";

ALTER TABLE "public"."priority_user"
    ADD CONSTRAINT "priority_user_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_user" validate CONSTRAINT "priority_user_user_id_fkey";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."series" validate CONSTRAINT "series_priority_id_fkey";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_unique" UNIQUE USING INDEX "series_unique";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."series" validate CONSTRAINT "series_user_id_fkey";

CREATE OR REPLACE FUNCTION public.is_finite (test tstzrange)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN NOT (lower_inf(test)
        OR upper_inf(test));
END;
$function$;

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_at_check" CHECK (is_finite (at)) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_at_check";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_pomodoro_check" CHECK (((pomodoro IS NULL) OR (pomodoro > 0))) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_pomodoro_check";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_priority_id_fkey";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_user_id_fkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."activity_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (activity a
    JOIN activity c ON (c.path <@ a.path));

CREATE OR REPLACE VIEW "public"."activity_tags" AS
SELECT
    sq.activity_id,
    sq.occurrence,
    jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE ((sq.actor_ids IS NOT NULL)
    AND (jsonb_array_length(sq.actor_ids) > 0))) AS tags,
max(sq.updated_at) AS updated_at,
(array_agg(sq.updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        at.activity_id,
        at.occurrence,
        at.tag_id,
        jsonb_agg(at.actor_id) FILTER (WHERE (at.deleted_at IS NULL)) AS actor_ids,
    max(COALESCE(at.deleted_at, at.updated_at)) AS updated_at,
    (array_agg(at.updated_by ORDER BY at.updated_at DESC))[1] AS updated_by
FROM
    activity_tag at
GROUP BY
    at.activity_id,
    at.occurrence,
    at.tag_id) sq
GROUP BY
    sq.activity_id,
    sq.occurrence;

CREATE OR REPLACE FUNCTION public.activity_thread (p_activity_id uuid)
    RETURNS SETOF activity
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY
    SELECT
        ac.*
    FROM
        activity a
        JOIN activity ac ON a.path <@ ac.path
            OR (nlevel (a.path) > 1
                AND subpath (a.path, 0, nlevel (a.path) - 1) = subpath (ac.path, 0, nlevel (ac.path) - 1))
    WHERE
        a.id = p_activity_id
        AND ac.created_at <= a.created_at
    ORDER BY
        ac.created_at;
END;
$function$;

CREATE OR REPLACE VIEW "public"."actor" AS
SELECT
    c.id,
    c.created_at,
    c.updated_at,
    CASE WHEN (c.user_id IS NOT NULL) THEN
        'user'::text
    ELSE
        'contact'::text
    END AS type,
    COALESCE(c.name, c.email) AS name,
    c.email,
    c.avatar_url
FROM
    contact c
UNION ALL
SELECT
    pa.id,
    pa.created_at,
    pa.updated_at,
    'priority_agent'::text AS type,
    pa.name,
    NULL::text AS email,
    NULL::text AS avatar_url
FROM
    priority_agent pa;

CREATE OR REPLACE FUNCTION public.actor (activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

CREATE OR REPLACE FUNCTION public.all_views_secure ()
    RETURNS boolean
    LANGUAGE plpgsql
    AS $function$
DECLARE
    VIEW text;
BEGIN
    SELECT
        relname INTO VIEW
    FROM
        pg_class
        JOIN pg_catalog.pg_namespace n ON n.oid = pg_class.relnamespace
    WHERE
        n.nspname = 'public'
        AND relname NOT LIKE '%_admin'
        AND relkind = 'v'
        AND (lower(reloptions::text)::text[] && ARRAY['security_invoker=1', 'security_invoker=true', 'security_invoker=on']) IS NULL;
    IF FOUND THEN
        RAISE EXCEPTION 'Found view without security_invoker: %', VIEW;
    END IF;
    RETURN TRUE;
END
$function$;

CREATE OR REPLACE FUNCTION public.can_access_priority (_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.priority_user cu
                JOIN public.priority c ON c.id = cu.priority_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.priority c2
                    WHERE
                        c2.id = _priority_id))
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    public.priority_user cu
                WHERE
                    cu.priority_id = _priority_id);
$function$;

CREATE OR REPLACE FUNCTION public.can_access_priority (_priority_path ltree)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.priority_user cu
                JOIN public.priority c ON c.id = cu.priority_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.priority c2
                    WHERE
                        c2.path = _priority_path));
$function$;

CREATE TYPE "public"."contact_upsert" AS (
    "calendar_id" bigint,
    "email" text,
    "name" text,
    "avatar_url" text
);

CREATE OR REPLACE FUNCTION public.count_not_null (val anyelement)
    RETURNS integer
    LANGUAGE sql
    IMMUTABLE
    AS $function$
    SELECT
        CASE WHEN val IS NULL THEN
            0
        ELSE
            1
        END;
$function$;

CREATE OR REPLACE FUNCTION public.get_accessible_agents (p_user_id uuid, p_priority_id uuid)
    RETURNS SETOF agent
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT DISTINCT
        agent.*
    FROM
        agent
    LEFT JOIN agent_access ON agent.id = agent_access.agent_id
    LEFT JOIN user_priority ON user_priority.user_id = p_user_id
        AND user_priority.id = agent_access.priority_membership_id
    LEFT JOIN priority access_priority ON agent_access.priority_access_id = access_priority.id
    LEFT JOIN priority target_priority ON target_priority.id = p_priority_id
WHERE
    agent.environment = 'public'
    OR (user_priority.id IS NOT NULL
        AND (agent_access.priority_access_id IS NULL
            OR target_priority.path <@ access_priority.path))
$function$;

CREATE OR REPLACE FUNCTION public.get_api_root ()
    RETURNS text
    LANGUAGE plpgsql
    STABLE
    AS $function$
BEGIN
    RETURN COALESCE(current_setting('plot.api_root', TRUE), 'http://host.docker.internal:8787/_');
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_domain (email text)
    RETURNS text
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
DECLARE
BEGIN
    RETURN lower(regexp_replace(split_part(email, '@', 2), '\s+', '', 'g'));
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_tag_type (tag_id integer)
    RETURNS tag_type
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    IF tag_id BETWEEN 1 AND 99 THEN
        RETURN 'compute'::tag_type;
    ELSIF tag_id BETWEEN 100 AND 999 THEN
        RETURN 'toggle'::tag_type;
    ELSE
        RETURN 'count'::tag_type;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_users_with_priority_access (target_priority_id uuid)
    RETURNS TABLE (
        user_id uuid)
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    AS $function$
BEGIN
    RETURN QUERY SELECT DISTINCT
        pu.user_id
    FROM
        priority_user pu
        JOIN priority p ON pu.priority_id = p.id
            OR (p.path <@ (
                    SELECT
                        path
                    FROM
                        priority
                WHERE
                    id = pu.priority_id))
    WHERE
        pu.deleted_at IS NULL
        AND p.id = get_users_with_priority_access.target_priority_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.handle_user_priority_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _priority_id uuid;
BEGIN
    _priority_id := NEW.id;
    IF (OLD IS NULL OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at OR NEW.title IS DISTINCT FROM OLD.title OR NEW.path IS DISTINCT FROM OLD.path OR NEW.updated_by IS DISTINCT FROM OLD.updated_by) THEN
        INSERT INTO priority (id, deleted_at, title, path, created_by, updated_by)
            VALUES (NEW.id, NEW.deleted_at, NEW.title, NEW.path, NEW.created_by, NEW.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                deleted_at = NEW.deleted_at,
                title = NEW.title,
                path = NEW.path,
                updated_by = NEW.updated_by
            RETURNING
                id INTO _priority_id;
    END IF;
    IF ((OLD IS NULL AND (NEW."path" IS NOT NULL OR NEW."top_order" IS NOT NULL OR NEW."pomodoro" IS NOT NULL OR NEW."color" IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."path" IS DISTINCT FROM OLD."path" OR NEW."top_order" IS DISTINCT FROM OLD."top_order" OR NEW."pomodoro" IS DISTINCT FROM OLD."pomodoro" OR NEW."color" IS DISTINCT FROM OLD."color"))) THEN
        INSERT INTO priority_settings (user_id, priority_id, path, top_order, pomodoro, color)
            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.path, NEW.top_order, NEW.pomodoro, NEW.color)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = COALESCE(NEW.path, priority_settings.path),
                top_order = COALESCE(NEW.top_order, priority_settings.top_order),
                pomodoro = COALESCE(NEW.pomodoro, priority_settings.pomodoro),
                color = COALESCE(NEW.color, priority_settings.color);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.insert_domain (email text)
    RETURNS bigint
    LANGUAGE plpgsql
    AS $function$
DECLARE
    domain_name text := get_domain (email);
    domain_id bigint;
    org_id bigint;
BEGIN
    SELECT
        id INTO domain_id
    FROM
        public.domain
    WHERE
        "name" = domain_name;
    IF NOT FOUND THEN
        INSERT INTO organization (name)
            VALUES (domain_name)
        RETURNING
            id INTO org_id;
        INSERT INTO public.domain (organization_id, "name")
            VALUES (org_id, domain_name);
    END IF;
    RETURN domain_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.insert_email_domain ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    IF NEW.email IS NULL THEN
        RETURN NEW;
    END IF;
    PERFORM
        public.insert_domain (NEW.email);
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.insert_priority_user ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    -- Only create entry for new, top-level priorities.
    IF nlevel (NEW.path) = 1 THEN
        INSERT INTO public.priority_user (user_id, priority_id)
            VALUES (NEW.created_by, NEW.id);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.migrate_existing_users_to_contacts ()
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _user_record record;
    _user_name text;
    _contact_id uuid;
    _updated_app_metadata jsonb;
BEGIN
    -- Loop through all existing auth users and create/update corresponding contacts
    FOR _user_record IN
    SELECT
        id,
        email,
        raw_app_meta_data
    FROM
        auth.users
    WHERE
        email IS NOT NULL LOOP
            -- Extract name from user metadata
            _user_name := COALESCE(_user_record.raw_app_meta_data ->> 'full_name', _user_record.raw_app_meta_data ->> 'name', _user_record.email);
            -- Upsert contact for this user and get contact ID
            _contact_id := public.upsert_user_contact (_user_record.id, _user_record.email, _user_name, _user_record.raw_app_meta_data ->> 'avatar_url');
            -- Update the user's app_metadata with contact_id
            _updated_app_metadata := COALESCE(_user_record.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('contact_id', _contact_id);
            -- Update the user record with the new app_metadata
            UPDATE
                auth.users
            SET
                raw_app_meta_data = _updated_app_metadata
            WHERE
                id = _user_record.id;
        END LOOP;
    RAISE NOTICE 'Migration completed: synchronized % users with contacts', (
        SELECT
            COUNT(*)
        FROM
            auth.users
        WHERE
            email IS NOT NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    agents_data jsonb;
    users_data jsonb;
    enriched_item jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
    ELSIF TG_OP = 'DELETE' THEN
        event_type := 'deleted';
        current_item := OLD;
    END IF;
    -- Extract agents query into a variable
    SELECT
        jsonb_agg(jsonb_build_object('agent_id', agent_id, 'priority_agent_id', id, 'config', config, 'version', version)) INTO agents_data
    FROM
        priority_child_agent
    WHERE
        priority_child_id = current_item.priority_id
        AND id != current_item.author_id;
    -- Get users who have access to this priority
    SELECT
        jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
    FROM
        public.get_users_with_priority_access (current_item.priority_id);
    -- Exit early if no agents or users found
    IF (agents_data IS NULL OR jsonb_array_length(agents_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item with author and priority information
    SELECT
        jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'author_id', current_item.author_id, 'assignee_id', current_item.assignee_id, 'updated_by', current_item.updated_by, 'deleted_at', current_item.deleted_at, 'priority_id', current_item.priority_id, 'type', current_item.type, 'path', current_item.path, 'order', current_item.order, 'draft', current_item.draft, 'private', current_item.private, 'title', current_item.title, 'note', current_item.note, 'links', current_item.links, 'at', current_item.at, 'on', current_item.on, 'duration', current_item.duration, 'done_at', current_item.done_at, 'recurrence_rule', current_item.recurrence_rule, 'recurrence_exdates', current_item.recurrence_exdates, 'recurrence_dates', current_item.recurrence_dates, 'source', current_item.source,
            -- Enriched data from JOINs
            'author_name', a.name, 'author_type', a.type, 'priority_title', p.title) INTO enriched_item
    FROM
        actor a,
        priority p
    WHERE
        a.id = current_item.author_id
        AND p.id = current_item.priority_id;
    -- Build the payload
    payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', enriched_item, 'agents', COALESCE(agents_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    users_data jsonb;
    enriched_item jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
    ELSIF TG_OP = 'DELETE' THEN
        event_type := 'deleted';
        current_item := OLD;
    END IF;
    -- Get users who have access to this priority (just the creator for now)
    SELECT
        jsonb_agg(jsonb_build_object('user_id', current_item.created_by)) INTO users_data;
    -- Exit early if no users found
    IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item
    enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'created_by', current_item.created_by, 'root', current_item.root, 'deleted_at', current_item.deleted_at, 'title', current_item.title, 'path', current_item.path, 'updated_by', current_item.updated_by);
    -- Build the payload (no agents for priority)
    payload := jsonb_build_object('type', 'priority', 'event', event_type, 'item', enriched_item, 'agents', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'priority');
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_session ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    users_data jsonb;
    enriched_item jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
    ELSIF TG_OP = 'DELETE' THEN
        event_type := 'deleted';
        current_item := OLD;
    END IF;
    -- Get user for this session
    SELECT
        jsonb_agg(jsonb_build_object('user_id', current_item.user_id)) INTO users_data;
    -- Exit early if no users found
    IF users_data IS NULL OR jsonb_array_length(users_data) = 0 THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item
    enriched_item := jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'deleted_at', current_item.deleted_at, 'user_id', current_item.user_id, 'priority_id', current_item.priority_id, 'at', current_item.at, 'precedence', current_item.precedence, 'pomodoro', current_item.pomodoro, 'pomodoro_at', current_item.pomodoro_at, 'updated_by', current_item.updated_by);
    -- Build the payload (no agents for session)
    payload := jsonb_build_object('type', 'session', 'event', event_type, 'item', enriched_item, 'agents', '[]'::jsonb, 'users', users_data, 'timestamp', extract(epoch FROM now()), 'table', 'session');
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE OR REPLACE FUNCTION public.organization (contact)
    RETURNS SETOF organization
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        organization.*
    FROM
        organization
        JOIN "domain" ON organization.id = domain.organization_id
    WHERE
        domain.name = get_domain ($1.email)
$function$;

CREATE OR REPLACE FUNCTION public.parent_path (p ltree)
    RETURNS ltree
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    IF nlevel (p) = 1 THEN
        RETURN p;
    END IF;
    RETURN subpath (p, 0, nlevel (p) - 1);
END;
$function$;

CREATE OR REPLACE VIEW "public"."priority_child" AS
SELECT
    p.id AS priority_id,
    c.id AS child_id
FROM (priority p
    JOIN priority c ON (c.path <@ p.path));

CREATE OR REPLACE VIEW "public"."priority_child_agent" AS
SELECT
    pa.id,
    pa.priority_id,
    pa.agent_id,
    pa.owner_id,
    pa.name,
    pa.config,
    pa.created_at,
    pa.updated_at,
    pa.deleted_at,
    a.version,
    aa.name AS author_name,
    aa.email AS author_email,
    aa.url AS author_url,
    pc.child_id AS priority_child_id
FROM (((priority_agent pa
            JOIN priority_child pc ON (pa.priority_id = pc.priority_id))
        JOIN agent a ON (pa.agent_id = a.id))
    LEFT JOIN agent_author aa ON (a.author_id = aa.id));

CREATE OR REPLACE VIEW "public"."priority_settings_inherited" AS SELECT DISTINCT ON (ps.user_id, p.id)
    ps.user_id,
    p.id AS priority_id,
    CASE WHEN ((nlevel (p.path) > nlevel (parent.path))
        AND (subpath (p.path, nlevel (parent.path)) <> ''::ltree)) THEN
        (ps.path || subpath (p.path, nlevel (parent.path)))
    ELSE
        ps.path
    END AS path,
    ps.pomodoro,
    ps.color
FROM ((priority_settings ps
        JOIN priority parent ON (ps.priority_id = parent.id))
    JOIN priority p ON (p.path <@ parent.path))
WHERE ((ps.path IS NOT NULL)
    OR (ps.pomodoro IS NOT NULL)
    OR (ps.color IS NOT NULL))
ORDER BY
    ps.user_id,
    p.id,
    (nlevel (p.path) - nlevel (parent.path));

CREATE OR REPLACE VIEW "public"."priority_tags" AS
SELECT
    a.priority_id,
    at.tag_id,
    count(*) AS count,
    max(COALESCE(at.deleted_at, at.updated_at)) AS updated_at
FROM (activity_tag at
    JOIN activity a ON (at.activity_id = a.id))
WHERE ((at.deleted_at IS NULL)
    AND (a.deleted_at IS NULL)
    AND (nlevel (a.path) = 1))
GROUP BY
    a.priority_id,
    at.tag_id;

CREATE OR REPLACE FUNCTION public.server_timestamp ()
    RETURNS timestamp with time zone
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_priority_agent_owner_id ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    NEW.owner_id := auth.uid ();
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_root_id_to_id ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    IF NEW.root_id IS NULL THEN
        NEW.root_id := NEW.id;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_user_contact_trigger ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _user_name text;
    _contact_id uuid;
    _updated_app_metadata jsonb;
BEGIN
    -- Extract name from user metadata
    _user_name := COALESCE(NEW.raw_app_meta_data ->> 'full_name', NEW.raw_app_meta_data ->> 'name', NEW.email);
    -- Upsert contact and get the contact ID
    _contact_id := public.upsert_user_contact (NEW.id, NEW.email, _user_name, NEW.raw_app_meta_data ->> 'avatar_url');
    -- Update the user's app_metadata with contact_id
    _updated_app_metadata := COALESCE(NEW.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('contact_id', _contact_id);
    -- Update the user record with the new app_metadata
    UPDATE
        auth.users
    SET
        raw_app_meta_data = _updated_app_metadata
    WHERE
        id = NEW.id;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.tstzrange_to_daterange (p_range tstzrange, p_timezone text DEFAULT 'UTC' ::text)
    RETURNS daterange
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN daterange((lower(p_range) AT TIME ZONE p_timezone)::date, (upper(p_range) AT TIME ZONE p_timezone)::date,
    -- preserve inclusive/exclusive bounds of original p_range
    CASE WHEN lower_inc(p_range)
        AND upper_inc(p_range) THEN
        '[]'
    WHEN lower_inc(p_range) THEN
        '[)'
    WHEN upper_inc(p_range) THEN
        '(]'
    ELSE
        '()'
    END)::daterange;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_activity_tags (p_activity_id uuid, p_user_id uuid, p_client_id integer, p_tag_updates jsonb)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    tag_record record;
    tag_id_int integer;
    is_adding boolean;
    current_tag_type tag_type;
BEGIN
    -- Iterate through the tag updates JSON object
    FOR tag_record IN
    SELECT
        key,
        value
    FROM
        jsonb_each(p_tag_updates)
        LOOP
            -- Convert key to integer and value to boolean
            tag_id_int := tag_record.key::integer;
            is_adding := tag_record.value::boolean;
            -- Get tag type using the get_tag_type function
            current_tag_type := get_tag_type (tag_id_int);
            IF is_adding THEN
                -- Adding a tag - use upsert to create or reactivate
                INSERT INTO activity_tag (user_id, activity_id, tag_id, updated_at, deleted_at, updated_by)
                    VALUES (p_user_id, p_activity_id, tag_id_int, now(), NULL, p_client_id)
                ON CONFLICT (user_id, activity_id, tag_id)
                    DO UPDATE SET
                        deleted_at = NULL,
                        updated_at = now(),
                        updated_by = p_client_id;
            ELSE
                -- Removing a tag - use update to soft delete existing records
                IF current_tag_type = 'toggle' THEN
                    -- For toggle tags, remove all users' tags
                    UPDATE
                        activity_tag
                    SET
                        deleted_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND deleted_at IS NULL;
                ELSE
                    -- For count/compute tags, only remove current user's tag
                    UPDATE
                        activity_tag
                    SET
                        deleted_at = now(),
                        updated_by = p_client_id
                    WHERE
                        activity_id = p_activity_id
                        AND tag_id = tag_id_int
                        AND user_id = p_user_id
                        AND deleted_at IS NULL;
                END IF;
            END IF;
        END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_author_id ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.author_id = COALESCE(user_contact_id (), NEW.author_id);
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_created_by ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.created_by = COALESCE(auth.uid (), NEW.created_by);
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_updated_at ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_activity (p_id uuid, p_user_id uuid, p_updated_by integer, p_deleted_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_priority_id uuid DEFAULT NULL::uuid, p_path ltree DEFAULT NULL::LTREE, p_draft boolean DEFAULT NULL::boolean, p_private boolean DEFAULT NULL::boolean, p_do_on date DEFAULT NULL::date, p_at tstzrange DEFAULT NULL::tstzrange, p_on daterange DEFAULT NULL::dateRANGE, p_duration interval DEFAULT NULL::interval, p_done_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_title text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_order double precision DEFAULT NULL::double precision, p_recurrence_rule text DEFAULT NULL::text, p_recurrence_exdates timestamp with time zone[] DEFAULT NULL::timestamp with time zone[], p_recurrence_dates timestamp with time zone[] DEFAULT NULL::timestamp with time zone[], p_series uuid DEFAULT NULL::uuid, p_occurrence_start timestamp with time zone DEFAULT NULL::timestamp with time zone)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    _activity_id uuid;
    _occurrence_root_id uuid;
    _occurrence_original_start timestamptz;
    _existing_path ltree;
BEGIN
    -- Convert series field to occurrence_root_id
    _occurrence_root_id := p_series;
    _occurrence_original_start := p_occurrence_start;
    -- Check if this is an update to an existing activity
    IF p_id IS NOT NULL THEN
        SELECT
            id INTO _activity_id
        FROM
            activity
        WHERE
            id = p_id;
    END IF;
    -- If updating a synthetic recurrence instance (generated ID), create a new exception record
    IF _activity_id IS NULL AND _occurrence_root_id IS NOT NULL AND _occurrence_original_start IS NOT NULL THEN
        -- This is a new exception for a recurring activity
        _activity_id := gen_random_uuid_v7 ();
        -- Get path from the root recurring activity if not provided
        IF p_path IS NULL THEN
            SELECT
                path INTO _existing_path
            FROM
                activity
            WHERE
                id = _occurrence_root_id;
            p_path := _existing_path;
        END IF;
        -- Insert new exception activity
        INSERT INTO activity (id, updated_by, deleted_at, priority_id, path, draft, private, do_on, at, "on", duration, done_at, title, note, "order", recurrence_rule, recurrence_exdates, recurrence_dates, occurrence_root_id, occurrence_original_start)
            VALUES (_activity_id, p_updated_by, p_deleted_at, COALESCE(p_priority_id, (
                        SELECT
                            priority_id
                        FROM activity
                        WHERE
                            id = _occurrence_root_id)),
                p_path,
                COALESCE(p_draft, FALSE),
                COALESCE(p_private, FALSE),
                p_do_on,
                p_at,
                p_on,
                p_duration,
                p_done_at,
                p_title,
                p_note,
                p_order,
                NULL, -- Exceptions don't have their own recurrence rules
                NULL,
                NULL,
                _occurrence_root_id,
                _occurrence_original_start);
        RETURN _activity_id;
    END IF;
    -- Handle path updates for recurring activity instances
    IF _occurrence_root_id IS NOT NULL AND p_path IS NOT NULL THEN
        -- Update path on the root recurring activity, not the instance
        UPDATE
            activity
        SET
            path = p_path,
            updated_at = now(),
            updated_by = p_updated_by
        WHERE
            id = _occurrence_root_id;
        -- Don't update the path on the exception instance
        p_path := NULL;
    END IF;
    -- Standard upsert for regular activities or existing exception records
    INSERT INTO activity (id, updated_by, deleted_at, priority_id, path, draft, private, do_on, at, "on", duration, done_at, title, note, "order", recurrence_rule, recurrence_exdates, recurrence_dates, occurrence_root_id, occurrence_original_start)
        VALUES (COALESCE(p_id, gen_random_uuid_v7 ()), p_updated_by, p_deleted_at, p_priority_id, p_path, COALESCE(p_draft, FALSE), COALESCE(p_private, FALSE), p_do_on, p_at, p_on, p_duration, p_done_at, p_title, p_note, COALESCE(p_order, public.order_first ()), p_recurrence_rule, p_recurrence_exdates, p_recurrence_dates, _occurrence_root_id, _occurrence_original_start)
    ON CONFLICT (id)
        DO UPDATE SET
            updated_by = EXCLUDED.updated_by,
            updated_at = now(),
            deleted_at = COALESCE(EXCLUDED.deleted_at, activity.deleted_at),
            priority_id = COALESCE(EXCLUDED.priority_id, activity.priority_id),
            path = COALESCE(EXCLUDED.path, activity.path),
            draft = COALESCE(EXCLUDED.draft, activity.draft),
            private = COALESCE(EXCLUDED.private, activity.private),
            do_on = COALESCE(EXCLUDED.do_on, activity.do_on),
            at = COALESCE(EXCLUDED.at, activity.at),
            "on" = COALESCE(EXCLUDED.on, activity.on),
            duration = COALESCE(EXCLUDED.duration, activity.duration),
            done_at = COALESCE(EXCLUDED.done_at, activity.done_at),
            title = COALESCE(EXCLUDED.title, activity.title),
            note = COALESCE(EXCLUDED.note, activity.note),
            "order" = COALESCE(EXCLUDED."order", activity."order"),
            recurrence_rule = COALESCE(EXCLUDED.recurrence_rule, activity.recurrence_rule),
            recurrence_exdates = COALESCE(EXCLUDED.recurrence_exdates, activity.recurrence_exdates),
            recurrence_dates = COALESCE(EXCLUDED.recurrence_dates, activity.recurrence_dates)
        RETURNING
            id INTO _activity_id;
    RETURN _activity_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_contacts (_contacts contact_upsert[])
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
BEGIN
    INSERT INTO contact (user_id, email, name, avatar_url) (
        SELECT
            a.user_id,
            vals.email,
            min(vals.name),
            min(vals.avatar_url)
        FROM
            unnest(_contacts) AS vals (calendar_id,
                email,
                name,
                avatar_url)
            JOIN calendar c ON vals.calendar_id = c.id
            JOIN account a ON c.account_id = a.id
        GROUP BY
            a.user_id,
            vals.email)
ON CONFLICT (user_id,
    email)
    DO UPDATE SET
        name = COALESCE(contact.name, EXCLUDED.name),
        avatar_url = COALESCE(contact.avatar_url, EXCLUDED.avatar_url);
END;
$function$;

CREATE OR REPLACE FUNCTION public.upsert_user_contact (user_id uuid, user_email text, user_name text, avatar_url text)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _contact_id uuid;
BEGIN
    -- Upsert contact record for the user
    INSERT INTO public.contact (email, name, avatar_url, user_id)
        VALUES (user_email, user_name, avatar_url, user_id)
    ON CONFLICT (email)
        DO UPDATE SET
            name = COALESCE(EXCLUDED.name, contact.name),
            avatar_url = COALESCE(EXCLUDED.avatar_url, contact.avatar_url),
            user_id = COALESCE(EXCLUDED.user_id, contact.user_id),
            updated_at = now()
        RETURNING
            id INTO _contact_id;
    RETURN _contact_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.user_contact_id ()
    RETURNS uuid
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN (auth.jwt () -> 'app_metadata' ->> 'contact_id')::uuid;
END;
$function$;

CREATE OR REPLACE FUNCTION public.user_has_priority_access (user_id uuid, target_priority_id uuid)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    AS $function$
BEGIN
    RETURN EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority p ON pu.priority_id = p.id
                OR (p.path <@ (
                        SELECT
                            path
                        FROM
                            priority
                    WHERE
                        id = pu.priority_id))
            WHERE
                pu.user_id = user_has_priority_access.user_id
                AND pu.deleted_at IS NULL
                AND p.id = user_has_priority_access.target_priority_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.user_has_priority_access (user_id uuid, target_priority_path ltree)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    AS $function$
BEGIN
    PERFORM
        set_config('row_security', 'off', TRUE);
    RETURN EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority pp ON pu.priority_id = pp.id
            JOIN priority p ON p.path <@ pp.path
        WHERE
            pu.user_id = user_has_priority_access.user_id
            AND pu.deleted_at IS NULL
            AND p.path = user_has_priority_access.target_priority_path);
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at) AS updated_at,
    GREATEST (pu.deleted_at, p.deleted_at) AS deleted_at,
    p.created_by,
    p.updated_by,
    (root.root
        AND (p.id = root.id)) AS root,
    p.title,
    CASE WHEN (inherited_settings.path IS NOT NULL) THEN
        inherited_settings.path
    WHEN (user_root.path @> p.path) THEN
        p.path
    ELSE
        (user_root.path || p.path)
    END AS path,
    settings.top_order,
    inherited_settings.pomodoro,
    inherited_settings.color
FROM (((((priority_user pu
                    JOIN priority root ON (pu.priority_id = root.id))
                JOIN priority user_root ON (((pu.user_id = user_root.created_by)
                            AND user_root.root)))
            JOIN priority p ON (root.path @> p.path))
        LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                    AND (p.id = settings.priority_id))))
    LEFT JOIN priority_settings_inherited inherited_settings ON (((inherited_settings.user_id = pu.user_id)
                AND (p.id = inherited_settings.priority_id))))
WHERE (pu.deleted_at IS NULL);

CREATE OR REPLACE FUNCTION public.user_timezone ()
    RETURNS text
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN COALESCE((auth.jwt () -> 'app_metadata' -> 'timezone')::text, 'America/New_York');
END;
$function$;

CREATE OR REPLACE FUNCTION public.week_from_date (d date)
    RETURNS daterange
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        CASE WHEN d IS NULL THEN
            NULL
        ELSE
            daterange(date_bin ('7 days', d, '2023-1-1'::date)::date, date_bin ('7 days', d, '2023-1-1'::date)::date + 7, '[)'::text)
        END
$function$;

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    up.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    a.deleted_at,
    a.priority_id,
    a.type,
    a.path,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.note,
    a.links,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
    a.source,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(a.created_at, a.created_at, '[]'::text)
    END AS range_at,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a.at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a."on" IS NOT NULL) THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on
FROM (activity a
    JOIN user_priority up ON (a.priority_id = up.id))
WHERE (up.deleted_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_activity_exception" AS
SELECT
    ua.user_id,
    ua.id,
    ae.occurrence,
    ae.updated_at,
    ua.range_at,
    ua.range_on,
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae.at
    ELSE
        NULL::tstzrange
    END AS at,
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae."on"
    ELSE
        NULL::daterange
    END AS "on",
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae.title
    ELSE
        NULL::text
    END AS title,
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae.note
    ELSE
        NULL::text
    END AS note
FROM (activity_exception ae
    JOIN user_activity ua ON (ua.id = ae.activity_id));

CREATE OR REPLACE VIEW "public"."user_activity_tags" AS
SELECT
    ua.user_id,
    ua.id,
    at.occurrence,
    at.updated_at,
    ua.range_at,
    ua.range_on,
    at.tags
FROM (activity_tags at
    JOIN user_activity ua ON (ua.id = at.activity_id));

CREATE POLICY "Users can delete their own activities" ON "public"."activity" AS permissive
    FOR DELETE TO public
        USING (((author_id = user_contact_id ()) AND user_has_priority_access (auth.uid (), priority_id)));

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR INSERT TO public
        WITH CHECK (((author_id = user_contact_id ()) AND user_has_priority_access (auth.uid (), priority_id)));

CREATE POLICY "Users can update their own activities" ON "public"."activity" AS permissive
    FOR UPDATE TO public
        USING (((author_id = user_contact_id ()) AND user_has_priority_access (auth.uid (), priority_id)));

CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR SELECT TO public
        USING (user_has_priority_access (auth.uid (), priority_id));

CREATE POLICY "Users can delete activity exceptions for their own activities" ON "public"."activity_exception" AS permissive
    FOR DELETE TO public
        USING ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND (activity.author_id = user_contact_id ()) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

CREATE POLICY "Users can insert activity exceptions for accessible activities" ON "public"."activity_exception" AS permissive
    FOR INSERT TO public
        WITH CHECK ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND (activity.author_id = user_contact_id ()) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

CREATE POLICY "Users can update activity exceptions for their own activities" ON "public"."activity_exception" AS permissive
    FOR UPDATE TO public
        USING ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND (activity.author_id = user_contact_id ()) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

CREATE POLICY "Users can view activity exceptions for accessible activities" ON "public"."activity_exception" AS permissive
    FOR SELECT TO public
        USING ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

CREATE POLICY "Users can insert activity_tag for activities in their accessibl" ON "public"."activity_tag" AS permissive
    FOR INSERT TO public
        WITH CHECK (((actor_id = auth.uid ()) AND (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id))))));

CREATE POLICY "Users can update activity_tag for activities in their accessibl" ON "public"."activity_tag" AS permissive
    FOR UPDATE TO public
        USING (((actor_id = auth.uid ()) OR (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id) AND (get_tag_type (activity_tag.tag_id) = 'toggle'::tag_type))))))
        WITH CHECK ((actor_id = auth.uid ()));

CREATE POLICY "Users can view activity_tag in their accessible priorities" ON "public"."activity_tag" AS permissive
    FOR SELECT TO public
        USING (((actor_id = auth.uid ()) OR (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access (auth.uid (), a.priority_id))))));

CREATE POLICY "Users can view contacts linked to their priorities" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING ((EXISTS (
            SELECT
                1
            FROM
                priority_contact pc
            WHERE ((pc.contact_id = contact.id) AND (pc.deleted_at IS NULL) AND user_has_priority_access (auth.uid (), pc.priority_id)))));

CREATE POLICY "Everyone can view all domains" ON "public"."domain" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "internal_admin can access all invitations" ON "public"."invitation" AS permissive
    FOR ALL TO internal_admin
        USING (TRUE);

CREATE POLICY "Everyone can view all organizations" ON "public"."organization" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "Users can access their priorities" ON "public"."priority" AS permissive
    FOR SELECT TO authenticated
        USING (can_access_priority (id));

CREATE POLICY "Users can create new priorities in their priorities" ON "public"."priority" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK (can_access_priority (parent_path (path)));

CREATE POLICY "Users can update their priorities" ON "public"."priority" AS permissive
    FOR UPDATE TO authenticated
        USING ((can_access_priority (id) AND ((deleted_at IS NULL) OR (root = FALSE))))
        WITH CHECK (((nlevel (path) = 1) OR can_access_priority (parent_path (path))));

CREATE POLICY "Users can delete agents in their accessible priorities" ON "public"."priority_agent" AS permissive
    FOR DELETE TO authenticated
        USING (can_access_priority (priority_id));

CREATE POLICY "Users can insert agents in their accessible priorities" ON "public"."priority_agent" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK ((can_access_priority (priority_id) AND (owner_id = auth.uid ())));

CREATE POLICY "Users can update agents in their accessible priorities" ON "public"."priority_agent" AS permissive
    FOR UPDATE TO authenticated
        USING (can_access_priority (priority_id))
        WITH CHECK ((can_access_priority (priority_id) AND (owner_id = auth.uid ())));

CREATE POLICY "Users can view agents in their accessible priorities" ON "public"."priority_agent" AS permissive
    FOR SELECT TO authenticated
        USING (can_access_priority (priority_id));

CREATE POLICY "Users can access priority contacts for their priorities" ON "public"."priority_contact" AS permissive
    FOR ALL TO authenticated
        USING (user_has_priority_access (auth.uid (), priority_id));

CREATE POLICY "Users can read/write their priority settings" ON "public"."priority_settings" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users change sharing for their priorities" ON "public"."priority_user" AS permissive
    FOR ALL TO authenticated
        USING (can_access_priority (priority_id));

CREATE POLICY "Users can edit their own series" ON "public"."series" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can edit their sessions" ON "public"."session" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE TRIGGER activity_change_api_call
    AFTER INSERT OR UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_activity ();

CREATE TRIGGER set_activity_author_id
    BEFORE INSERT ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION update_author_id ();

CREATE TRIGGER set_activity_updated_at
    BEFORE UPDATE ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_activity_tag_updated_at
    BEFORE UPDATE ON public.activity_tag
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER agent_set_root_id
    BEFORE INSERT ON public.agent
    FOR EACH ROW
    EXECUTE FUNCTION set_root_id_to_id ();

CREATE TRIGGER set_agent_updated_at
    BEFORE UPDATE ON public.agent
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_agent_access_updated_at
    BEFORE UPDATE ON public.agent_access
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_agent_author_updated_at
    BEFORE UPDATE ON public.agent_author
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_agent_token_updated_at
    BEFORE UPDATE ON public.agent_token
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER on_contact_created
    AFTER INSERT ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION insert_email_domain ();

CREATE TRIGGER handle_priority_changes
    AFTER INSERT OR UPDATE ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_priority ();

CREATE TRIGGER priority_insert_trigger
    AFTER INSERT ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION insert_priority_user ();

CREATE TRIGGER set_priority_created_by
    BEFORE INSERT ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

CREATE TRIGGER set_priority_updated_at
    BEFORE UPDATE ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_agent_updated_at
    BEFORE UPDATE ON public.priority_agent
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_agent_owner_id
    BEFORE INSERT ON public.priority_agent
    FOR EACH ROW
    EXECUTE FUNCTION set_priority_agent_owner_id ();

CREATE TRIGGER set_priority_user_updated_at
    BEFORE UPDATE ON public.priority_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_user_updated_at
    BEFORE UPDATE ON public.priority_user
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_series_updated_at
    BEFORE UPDATE ON public.series
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER handle_session_changes
    AFTER INSERT OR UPDATE ON public.session
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_session ();

CREATE TRIGGER set_session_updated_at
    BEFORE UPDATE ON public.session
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

CREATE OR REPLACE VIEW "admin"."invitation" WITH ( security_invoker = FALSE)
-- for formatting
AS
SELECT
    min(i.id) AS id,
    min(i.created_at) AS created_at,
    min(i.code) AS code,
    min(i.remaining) AS remaining
FROM
    invitation i
GROUP BY
    i.id;

CREATE TRIGGER on_user_created_sync_contact
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_user_contact_trigger ();

CREATE TRIGGER on_user_updated_sync_contact
    AFTER UPDATE ON auth.users
    FOR EACH ROW
    WHEN (OLD.email IS DISTINCT FROM NEW.email OR OLD.raw_app_meta_data IS DISTINCT FROM NEW.raw_app_meta_data)
    EXECUTE FUNCTION public.sync_user_contact_trigger ();

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_agent" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

