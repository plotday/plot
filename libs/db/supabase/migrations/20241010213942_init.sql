CREATE SCHEMA IF NOT EXISTS "extensions";

CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "btree_gist" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "ltree" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;

CREATE EXTENSION IF NOT EXISTS pg_tle;

SELECT
    pgtle.uninstall_extension_if_exists ('supabase-dbdev');

SELECT
    pgtle.install_extension ('supabase-dbdev', resp.contents ->> 'version', 'PostgreSQL package manager', resp.contents ->> 'sql')
FROM
    http (('GET', 'https://api.database.dev/rest/v1/' || 'package_versions?select=sql,version' || '&package_name=eq.supabase-dbdev' || '&order=version.desc' || '&limit=1', ARRAY[('apiKey', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhtdXB0cHBsZnZpaWZyYndtbXR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE2ODAxMDczNzIsImV4cCI6MTk5NTY4MzM3Mn0.z2CN0mvO2No8wSi46Gw59DFGCTJrzM0AQKsu_5k134s')::http_header], NULL, NULL)) x,
    LATERAL (
        SELECT
            ((row_to_json(x) -> 'content') #>> '{}')::json -> 0) resp (contents);

CREATE EXTENSION "supabase-dbdev";

SELECT
    dbdev.install ('supabase-dbdev');

DROP EXTENSION IF EXISTS "supabase-dbdev";

CREATE EXTENSION "supabase-dbdev";

SELECT
    *
FROM
    dbdev.install ('kiwicopple-pg_idkit');

CREATE EXTENSION "kiwicopple-pg_idkit" WITH SCHEMA extensions;

CREATE TYPE "public"."budget_type" AS enum (
    'default',
    'exception'
);

CREATE TYPE "public"."event_availability" AS enum (
    'busy',
    'away',
    'focus',
    'free',
    'location'
);

CREATE TYPE "public"."event_internal" AS enum (
    'internal',
    'external'
);

CREATE TYPE "public"."event_response" AS enum (
    'accepted',
    'declined',
    'tentative'
);

CREATE TYPE "public"."event_status" AS enum (
    'confirmed',
    'cancelled',
    'tentative'
);

CREATE TYPE "public"."event_type" AS enum (
    'meeting',
    'task',
    'note'
);

CREATE TYPE "public"."event_visibility" AS enum (
    'normal',
    'private',
    'confidential',
    'public',
    'personal'
);

CREATE TYPE "public"."location_type" AS enum (
    'room',
    'address',
    'other'
);

CREATE TYPE "public"."meeting_size" AS enum (
    '1:1',
    'Small',
    'Medium',
    'Large',
    'XL',
    'XXL'
);

CREATE TYPE "public"."provider" AS enum (
    'google',
    'outlook'
);

CREATE TABLE "public"."account" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "email" text NOT NULL,
    "credentials" jsonb,
    "contact_sync_state" jsonb
);

ALTER TABLE "public"."account" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."budget" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "context_id" uuid,
    "week" daterange NOT NULL,
    "seconds" integer,
    "type" budget_type NOT NULL DEFAULT 'default' ::budget_type
);

ALTER TABLE "public"."budget" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."calendar" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "account_id" bigint NOT NULL,
    "provider_id" text NOT NULL,
    "synced_dates" tstzrange,
    "sync_state" text,
    "watch_id" text,
    "watch_secret" text,
    "watch_expires_at" timestamp with time zone,
    "sequence" numeric NOT NULL DEFAULT '1' ::numeric,
    "full_sync_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    "sync_error" text,
    "full_sync_started_at" timestamp with time zone,
    "name" text,
    "enabled" boolean NOT NULL DEFAULT FALSE,
    "ready" boolean NOT NULL DEFAULT FALSE
);

ALTER TABLE "public"."calendar" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."contact" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "email" text NOT NULL,
    "name" text,
    "avatar_url" text
);

ALTER TABLE "public"."contact" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."context" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL,
    "name" text NOT NULL,
    "path" ltree NOT NULL
);

ALTER TABLE "public"."context" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."context_settings" (
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "context_id" uuid NOT NULL,
    "order" double precision NOT NULL,
    "pomodoro" integer NOT NULL DEFAULT (25 * 60)
);

ALTER TABLE "public"."context_settings" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."context_user" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "context_id" uuid NOT NULL,
    "path" ltree
);

ALTER TABLE "public"."context_user" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."domain" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL,
    "organization_id" bigint
);

ALTER TABLE "public"."domain" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."event" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "calendar_id" bigint,
    "provider_id" text NOT NULL DEFAULT (gen_random_uuid ()) ::text,
    "series" text,
    "name" text,
    "status" event_status NOT NULL DEFAULT 'confirmed' ::event_status,
    "response" event_response,
    "visibility" event_visibility NOT NULL DEFAULT 'normal' ::event_visibility,
    "availability" event_availability NOT NULL DEFAULT 'busy' ::event_availability,
    "at" tstzrange NOT NULL,
    "provider_link" text,
    "summary" text,
    "description" text,
    "conferencing_url" text,
    "organizer_email" text,
    "sequence" integer NOT NULL DEFAULT 1,
    "optional" boolean NOT NULL DEFAULT FALSE,
    "invitees_hidden" boolean NOT NULL DEFAULT FALSE
);

ALTER TABLE "public"."event" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."invitation" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "code" text NOT NULL,
    "remaining" numeric NOT NULL DEFAULT '1' ::numeric
);

ALTER TABLE "public"."invitation" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."invitee" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "event_id" uuid,
    "email" text NOT NULL,
    "response" event_response,
    "is_optional" boolean NOT NULL DEFAULT FALSE
);

ALTER TABLE "public"."invitee" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."note" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "context_id" uuid,
    "topic_id" uuid NOT NULL,
    "body" text NOT NULL,
    "order" double precision NOT NULL,
    "root" boolean NOT NULL DEFAULT TRUE,
    "private" boolean NOT NULL DEFAULT FALSE
);

ALTER TABLE "public"."note" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."organization" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL
);

ALTER TABLE "public"."organization" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."raw_event" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "calendar_id" bigint,
    "event" jsonb NOT NULL,
    "provider_id" text NOT NULL
);

ALTER TABLE "public"."raw_event" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."series" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "series" text NOT NULL,
    "invitees" text[],
    "embedding" vector (384),
    "context_id" uuid
);

ALTER TABLE "public"."series" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."session" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "context_id" uuid,
    "at" tstzrange NOT NULL,
    "priority" smallint NOT NULL DEFAULT 0,
    "pomodoro" smallint,
    "pomodoro_at" timestamp with time zone
);

ALTER TABLE "public"."session" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."tag" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "note_id" uuid NOT NULL,
    "emoji" text NOT NULL
);

ALTER TABLE "public"."tag" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."waitlist" (
    "id" bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "email" text NOT NULL,
    "invitation" text,
    "activated_at" timestamp with time zone
);

ALTER TABLE "public"."waitlist" ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX account_pkey ON public.account USING btree (id);

CREATE UNIQUE INDEX account_user_id_email_key ON public.account USING btree (user_id, email);

CREATE INDEX account_user_id_idx ON public.account USING btree (user_id);

CREATE UNIQUE INDEX budget_pkey ON public.budget USING btree (id);

CREATE INDEX calendar_account_id_idx ON public.calendar USING btree (account_id);

CREATE UNIQUE INDEX calendar_account_provider_id_unique ON public.calendar USING btree (account_id, provider_id);

CREATE UNIQUE INDEX calendar_pkey ON public.calendar USING btree (id);

CREATE UNIQUE INDEX calendar_provider_id_unique ON public.raw_event USING btree (calendar_id, provider_id);

CREATE UNIQUE INDEX contact_pkey ON public.contact USING btree (id);

CREATE UNIQUE INDEX contact_user_email_unique ON public.contact USING btree (user_id, email) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX context_path_key ON public.context USING btree (path);

CREATE UNIQUE INDEX context_pkey ON public.context USING btree (id);

CREATE UNIQUE INDEX context_user_user_path_unique ON public.context_user USING btree (user_id, path);

CREATE UNIQUE INDEX domain_name_key ON public.domain USING btree (name);

CREATE UNIQUE INDEX domain_pkey ON public.domain USING btree (id);

CREATE INDEX event_at_idx ON public.event USING spgist (at);

CREATE UNIQUE INDEX event_calendar_provider_id_unique ON public.event USING btree (calendar_id, provider_id) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX event_pkey ON public.event USING btree (id);

CREATE UNIQUE INDEX invitation_code_key ON public.invitation USING btree (code);

CREATE UNIQUE INDEX invitation_pkey ON public.invitation USING btree (id);

CREATE UNIQUE INDEX invitee_event_email_unique ON public.invitee USING btree (event_id, email);

CREATE INDEX invitee_event_id_idx ON public.invitee USING btree (event_id);

CREATE INDEX name ON public.domain USING btree (name);

CREATE UNIQUE INDEX note_order_root ON public.note USING btree (context_id, "order")
WHERE (root = TRUE);

CREATE UNIQUE INDEX note_order_topic ON public.note USING btree (context_id, topic_id, "order")
WHERE (root = FALSE);

CREATE UNIQUE INDEX note_pkey ON public.note USING btree (id);

CREATE UNIQUE INDEX note_topic_root ON public.note USING btree (context_id, topic_id)
WHERE (root = TRUE);

CREATE UNIQUE INDEX organization_pkey ON public.organization USING btree (id);

CREATE UNIQUE INDEX priority_user_context_week_unique ON public.budget USING btree (user_id, context_id, week) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX raw_event_pkey ON public.raw_event USING btree (id);

CREATE UNIQUE INDEX series_pkey ON public.series USING btree (id);

CREATE UNIQUE INDEX series_unique ON public.series USING btree (user_id, series);

CREATE INDEX session_at_idx ON public.session USING spgist (at);

CREATE UNIQUE INDEX session_pkey ON public.session USING btree (id);

CREATE UNIQUE INDEX tag_pkey ON public.tag USING btree (id);

CREATE UNIQUE INDEX tag_user_id_note_id_emoji_key ON public.tag USING btree (user_id, note_id, emoji);

CREATE UNIQUE INDEX user_context_unique ON public.context_settings USING btree (user_id, context_id);

CREATE UNIQUE INDEX waitlist_pkey ON public.waitlist USING btree (id);

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.account (calendar)
    RETURNS SETOF account
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        account.*
    FROM
        account
    WHERE
        account.id = $1.account_id
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

CREATE OR REPLACE FUNCTION public.budget (context)
    RETURNS SETOF budget
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        *
    FROM
        budget
    WHERE
        context_id = $1.id;
$function$;

CREATE FUNCTION calc_seconds (r tstzrange)
    RETURNS integer
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN round(EXTRACT(epoch FROM (upper(r) - lower(r))))::integer;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calc_all_day (at tstzrange)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
DECLARE
    seconds integer = calc_seconds (at);
BEGIN
    RETURN seconds >= 60 * 23;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calc_event_type (at tstzrange, availability event_availability, response event_response, has_invitees boolean)
    RETURNS event_type
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN CASE WHEN (response != 'declined'
        AND availability = 'free')
        OR availability = 'away'
        OR calc_all_day (at) THEN
        'note'::event_type
    WHEN availability = 'focus' THEN
        'task'::event_type
    WHEN has_invitees THEN
        'meeting'::event_type
    ELSE
        'task'::event_type
    END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calc_internal (invitee_count integer, user_domain bigint, domains bigint[])
    RETURNS event_internal
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN CASE WHEN invitee_count < 2
        OR user_domain IS NULL THEN
        NULL
    WHEN ARRAY[user_domain] = domains THEN
        'internal'::event_internal
    ELSE
        'external'::event_internal
    END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calc_meeting_size (invitee_count integer)
    RETURNS text
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN CASE WHEN invitee_count = 2 THEN
        '1:1'
    WHEN invitee_count <= 4 THEN
        'Small'
    WHEN invitee_count <= 7 THEN
        'Medium'
    WHEN invitee_count <= 15 THEN
        'Large'
    WHEN invitee_count <= 30 THEN
        'XL'
    ELSE
        'XXL'
    END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calc_notice (created_at timestamp with time zone, at tstzrange)
    RETURNS integer
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN CASE WHEN created_at IS NULL THEN
        NULL
    WHEN created_at > LOWER(at) THEN
        0
    ELSE
        EXTRACT(EPOCH FROM (LOWER(at) - created_at))::integer
    END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calc_rounded_length (at tstzrange)
    RETURNS integer
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
DECLARE
    seconds integer = calc_seconds (at);
BEGIN
    RETURN CASE WHEN seconds <= 20 THEN
        15
    WHEN seconds < 40 THEN
        30
    WHEN seconds < 50 THEN
        45
    WHEN seconds < 75 THEN
        60
    WHEN seconds < 101 THEN
        90
    WHEN seconds < 131 THEN
        120
    WHEN seconds < 161 THEN
        150
    WHEN seconds <= 180 THEN
        180
    WHEN seconds <= 300 THEN
        240
    WHEN seconds <= 420 THEN
        360
    ELSE
        480
    END;
END;
$function$;

CREATE OR REPLACE FUNCTION public.calc_speedy (at tstzrange)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
DECLARE
    seconds integer = calc_seconds (at);
BEGIN
    RETURN seconds < 30
        OR (MOD(seconds, 30) >= 10
            AND MOD(seconds, 30) <= 15);
END;
$function$;

CREATE OR REPLACE FUNCTION public.calendars (account)
    RETURNS SETOF calendar
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        calendar.*
    FROM
        calendar
    WHERE
        calendar.account_id = $1.id
$function$;

CREATE OR REPLACE FUNCTION public.can_access_context (_context_id uuid)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.context_user cu
                JOIN public.context c ON c.id = cu.context_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.context c2
                    WHERE
                        c2.id = _context_id))
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    public.context_user cu
                WHERE
                    cu.context_id = _context_id);
$function$;

CREATE OR REPLACE FUNCTION public.can_access_context (_context_path ltree)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.context_user cu
                JOIN public.context c ON c.id = cu.context_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.context c2
                    WHERE
                        c2.path = _context_path));
$function$;

CREATE TYPE "public"."event_ids" AS (
    "calendar_id" bigint,
    "provider_id" text
);

CREATE OR REPLACE FUNCTION public.cancel_events (_events event_ids[])
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
BEGIN
    FOR i IN 1..array_length(_events, 1)
    LOOP
        UPDATE
            public.event
        SET
            status = 'cancelled'
        WHERE
            calendar_id = _events[i].calendar_id
            AND provider_id = _events[i].provider_id;
    END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.contact (invitee)
    RETURNS SETOF contact
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        contact.*
    FROM
        contact
    WHERE
        contact.email = $1.email
$function$;

CREATE TYPE "public"."contact_upsert" AS (
    "calendar_id" bigint,
    "email" text,
    "name" text,
    "avatar_url" text
);

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

CREATE OR REPLACE FUNCTION public.handle_context_x_insert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    context_id uuid;
BEGIN
    context_id := NEW.id;
    IF context_id IS NULL THEN
        context_id := gen_random_uuid_v7 ();
    END IF;
    INSERT INTO context (id, name, path, created_by)
        VALUES (context_id, NEW.name, NEW.path, auth.uid ());
    IF NEW.order IS NOT NULL OR NEW.pomodoro IS NOT NULL THEN
        INSERT INTO context_settings (user_id, context_id, "order", pomodoro)
            VALUES (auth.uid (), context_id, NEW.order, COALESCE(NEW.pomodoro, 25));
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.handle_context_x_update ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    IF NEW.name IS DISTINCT FROM OLD.name OR NEW.path IS DISTINCT FROM OLD.path THEN
        UPDATE
            context
        SET
            name = NEW.name,
            path = NEW.path
        WHERE
            id = NEW.id;
    END IF;
    IF NEW."order" IS DISTINCT FROM OLD."order" OR NEW.pomodoro IS DISTINCT FROM OLD.pomodoro THEN
        -- Upsert context_settings
        INSERT INTO context_settings (user_id, context_id, "order", pomodoro)
            VALUES (auth.uid (), NEW.id, NEW.order, COALESCE(NEW.pomodoro, 25))
        ON CONFLICT (user_id, context_id)
            DO UPDATE SET
                "order" = COALESCE(NEW.order, context_settings."order"), pomodoro = COALESCE(NEW.pomodoro, context_settings.pomodoro);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.insert_context_user ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    IF nlevel (NEW.path) = 1 THEN
        INSERT INTO public.context_user (created_at, modified_at, user_id, context_id)
            VALUES (now(), now(), NEW.created_by, NEW.id);
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

CREATE OR REPLACE VIEW "public"."invitation_admin" AS
SELECT
    min(i.id) AS id,
    min(i.created_at) AS created_at,
    min(i.code) AS code,
    min(i.remaining) AS remaining,
    count(w.invitation) AS uses
FROM (invitation i
    LEFT JOIN waitlist w ON (w.invitation = i.code))
GROUP BY
    i.id;

CREATE TYPE "public"."invitee_upsert" AS (
    "event_id" uuid,
    "email" text,
    "response" event_response,
    "is_optional" boolean
);

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

CREATE OR REPLACE FUNCTION public.is_lower (text)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN $1 = lower($1);
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_week (p_week daterange)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN p_week IS NULL
        OR EXTRACT(DOW FROM lower(p_week)) = 0
        AND upper(p_week) - lower(p_week) = 7;
END;
$function$;

CREATE OR REPLACE FUNCTION public.organization (account)
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

CREATE OR REPLACE FUNCTION public.redeem_invitation (_user_id bigint, _invitation text)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
BEGIN
    UPDATE
        "invitation"
    SET
        remaining = remaining - 1
    WHERE
        code = _invitation
        AND remaining > 0;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Invitation code % not valid', _invitation;
    END IF;
    BEGIN
        UPDATE
            public.user
        SET
            invitation = _invitation,
            activated_at = now()
        WHERE
            id = _user_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'User % not found', _user_id;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            UPDATE
                "invitation"
            SET
                remaining = remaining + 1
            WHERE
                code = _invitation;
    RAISE;
    END;
END;

$function$;

CREATE OR REPLACE FUNCTION public.replace_parent_path (parent_path ltree, child_path ltree, new_parent_path ltree)
    RETURNS ltree
    LANGUAGE plpgsql
    AS $function$
BEGIN
    IF child_path = parent_path THEN
        RETURN new_parent_path;
    ELSIF child_path <@ parent_path THEN
        RETURN new_parent_path || subpath (child_path, nlevel (parent_path));
    ELSE
        RETURN child_path;
    END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_created_by ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.created_by = auth.uid ();
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_modified_at ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    NEW.modified_at = now();
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_topic_root (note_id uuid)
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _root_order text;
    _context_id uuid;
    _topic_id uuid;
BEGIN
    -- Start a transaction block
    BEGIN
        -- Find the context_id and topic_id for the given ID
        SELECT
            context_id,
            topic_id INTO _context_id,
            _topic_id
        FROM
            "public"."note"
        WHERE
            id = note_id;
        -- Find the previous root and capture the order value
        SELECT
            "order" INTO _root_order
        FROM
            "public"."note"
        WHERE (context_id IS NOT DISTINCT FROM _context_id)
            AND topic_id = _topic_id
            AND root = TRUE
        FOR UPDATE;
        -- Update previous root record to set root = false and order = '!'
        UPDATE
            "public"."note"
        SET
            root = FALSE,
            "order" = '!'
        WHERE (context_id IS NOT DISTINCT FROM _context_id)
            AND topic_id = _topic_id
            AND root = TRUE;
        -- Update the row for the given id to set root = true and order previous order
        UPDATE
            "public"."note"
        SET
            root = TRUE,
            "order" = _root_order
        WHERE
            id = note_id;
    EXCEPTION
        WHEN OTHERS THEN
            -- Rollback the transaction if any exception occurs
            RAISE;
    END;
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

CREATE OR REPLACE FUNCTION public.upsert_invitees (_event_ids uuid[], _invitees invitee_upsert[])
    RETURNS void
    LANGUAGE plpgsql
    AS $function$
BEGIN
    DELETE FROM invitee
    WHERE event_id = ANY (_event_ids);
    INSERT INTO invitee (event_id, email, response, is_optional) (
        SELECT
            vals.event_id,
            vals._email,
            min(vals.response),
            bool_and(vals.is_optional)
        FROM
            unnest(_invitees) AS vals (event_id,
                _email,
                response,
                is_optional)
        GROUP BY
            event_id,
            _email)
ON CONFLICT (event_id,
    email)
    DO UPDATE SET
        response = EXCLUDED.response,
        is_optional = EXCLUDED.is_optional;
END;
$function$;

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

CREATE OR REPLACE FUNCTION public.work_day_end ()
    RETURNS time without time zone
    LANGUAGE sql
    IMMUTABLE PARALLEL SAFE
    AS $function$
    SELECT
        '17:00'::time
$function$;

CREATE OR REPLACE FUNCTION public.work_day_start ()
    RETURNS time without time zone
    LANGUAGE sql
    IMMUTABLE PARALLEL SAFE
    AS $function$
    SELECT
        '09:00'::time
$function$;

ALTER TABLE "public"."account"
    ADD CONSTRAINT "account_pkey" PRIMARY KEY USING INDEX "account_pkey";

ALTER TABLE "public"."budget"
    ADD CONSTRAINT "budget_pkey" PRIMARY KEY USING INDEX "budget_pkey";

ALTER TABLE "public"."calendar"
    ADD CONSTRAINT "calendar_pkey" PRIMARY KEY USING INDEX "calendar_pkey";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_pkey" PRIMARY KEY USING INDEX "contact_pkey";

ALTER TABLE "public"."context"
    ADD CONSTRAINT "context_pkey" PRIMARY KEY USING INDEX "context_pkey";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_pkey" PRIMARY KEY USING INDEX "domain_pkey";

ALTER TABLE "public"."event"
    ADD CONSTRAINT "event_pkey" PRIMARY KEY USING INDEX "event_pkey";

ALTER TABLE "public"."invitation"
    ADD CONSTRAINT "invitation_pkey" PRIMARY KEY USING INDEX "invitation_pkey";

ALTER TABLE "public"."note"
    ADD CONSTRAINT "note_pkey" PRIMARY KEY USING INDEX "note_pkey";

ALTER TABLE "public"."organization"
    ADD CONSTRAINT "organization_pkey" PRIMARY KEY USING INDEX "organization_pkey";

ALTER TABLE "public"."raw_event"
    ADD CONSTRAINT "raw_event_pkey" PRIMARY KEY USING INDEX "raw_event_pkey";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_pkey" PRIMARY KEY USING INDEX "series_pkey";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_pkey" PRIMARY KEY USING INDEX "session_pkey";

ALTER TABLE "public"."tag"
    ADD CONSTRAINT "tag_pkey" PRIMARY KEY USING INDEX "tag_pkey";

ALTER TABLE "public"."waitlist"
    ADD CONSTRAINT "waitlist_pkey" PRIMARY KEY USING INDEX "waitlist_pkey";

ALTER TABLE "public"."account"
    ADD CONSTRAINT "account_email_check" CHECK (is_lower (email)) NOT valid;

ALTER TABLE "public"."account" validate CONSTRAINT "account_email_check";

ALTER TABLE "public"."account"
    ADD CONSTRAINT "account_user_id_email_key" UNIQUE USING INDEX "account_user_id_email_key";

ALTER TABLE "public"."account"
    ADD CONSTRAINT "account_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."account" validate CONSTRAINT "account_user_id_fkey";

ALTER TABLE "public"."budget"
    ADD CONSTRAINT "budget_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."budget" validate CONSTRAINT "budget_context_id_fkey";

ALTER TABLE "public"."budget"
    ADD CONSTRAINT "budget_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."budget" validate CONSTRAINT "budget_user_id_fkey";

ALTER TABLE "public"."budget"
    ADD CONSTRAINT "budget_week_check" CHECK (is_week (week)) NOT valid;

ALTER TABLE "public"."budget" validate CONSTRAINT "budget_week_check";

ALTER TABLE "public"."budget"
    ADD CONSTRAINT "priority_user_context_week_unique" UNIQUE USING INDEX "priority_user_context_week_unique";

ALTER TABLE "public"."calendar"
    ADD CONSTRAINT "calendar_account_id_fkey" FOREIGN KEY (account_id) REFERENCES account (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."calendar" validate CONSTRAINT "calendar_account_id_fkey";

ALTER TABLE "public"."calendar"
    ADD CONSTRAINT "calendar_account_provider_id_unique" UNIQUE USING INDEX "calendar_account_provider_id_unique";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_email_check" CHECK (is_lower (email)) NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_email_check";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_email_unique" UNIQUE USING INDEX "contact_user_email_unique";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_user_id_fkey";

ALTER TABLE "public"."context"
    ADD CONSTRAINT "context_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."context" validate CONSTRAINT "context_created_by_fkey";

ALTER TABLE "public"."context"
    ADD CONSTRAINT "context_path_key" UNIQUE USING INDEX "context_path_key";

ALTER TABLE "public"."context_settings"
    ADD CONSTRAINT "context_settings_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."context_settings" validate CONSTRAINT "context_settings_context_id_fkey";

ALTER TABLE "public"."context_settings"
    ADD CONSTRAINT "context_settings_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."context_settings" validate CONSTRAINT "context_settings_user_id_fkey";

ALTER TABLE "public"."context_settings"
    ADD CONSTRAINT "user_context_unique" UNIQUE USING INDEX "user_context_unique";

ALTER TABLE "public"."context_user"
    ADD CONSTRAINT "context_user_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."context_user" validate CONSTRAINT "context_user_context_id_fkey";

ALTER TABLE "public"."context_user"
    ADD CONSTRAINT "context_user_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."context_user" validate CONSTRAINT "context_user_user_id_fkey";

ALTER TABLE "public"."context_user"
    ADD CONSTRAINT "context_user_user_path_unique" UNIQUE USING INDEX "context_user_user_path_unique";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_name_check" CHECK (is_lower (name)) NOT valid;

ALTER TABLE "public"."domain" validate CONSTRAINT "domain_name_check";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_name_key" UNIQUE USING INDEX "domain_name_key";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES organization (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."domain" validate CONSTRAINT "domain_organization_id_fkey";

ALTER TABLE "public"."event"
    ADD CONSTRAINT "event_calendar_id_fkey" FOREIGN KEY (calendar_id) REFERENCES calendar (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."event" validate CONSTRAINT "event_calendar_id_fkey";

ALTER TABLE "public"."event"
    ADD CONSTRAINT "event_calendar_provider_id_unique" UNIQUE USING INDEX "event_calendar_provider_id_unique";

ALTER TABLE "public"."event"
    ADD CONSTRAINT "event_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."event" validate CONSTRAINT "event_user_id_fkey";

ALTER TABLE "public"."invitation"
    ADD CONSTRAINT "invitation_code_key" UNIQUE USING INDEX "invitation_code_key";

ALTER TABLE "public"."invitee"
    ADD CONSTRAINT "invitee_email_check" CHECK (is_lower (email)) NOT valid;

ALTER TABLE "public"."invitee" validate CONSTRAINT "invitee_email_check";

ALTER TABLE "public"."invitee"
    ADD CONSTRAINT "invitee_event_email_unique" UNIQUE USING INDEX "invitee_event_email_unique";

ALTER TABLE "public"."invitee"
    ADD CONSTRAINT "invitee_event_id_fkey" FOREIGN KEY (event_id) REFERENCES event (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."invitee" validate CONSTRAINT "invitee_event_id_fkey";

ALTER TABLE "public"."note"
    ADD CONSTRAINT "note_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."note" validate CONSTRAINT "note_context_id_fkey";

ALTER TABLE "public"."note"
    ADD CONSTRAINT "note_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."note" validate CONSTRAINT "note_user_id_fkey";

ALTER TABLE "public"."raw_event"
    ADD CONSTRAINT "calendar_provider_id_unique" UNIQUE USING INDEX "calendar_provider_id_unique";

ALTER TABLE "public"."raw_event"
    ADD CONSTRAINT "raw_event_calendar_id_fkey" FOREIGN KEY (calendar_id) REFERENCES calendar (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."raw_event" validate CONSTRAINT "raw_event_calendar_id_fkey";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."series" validate CONSTRAINT "series_context_id_fkey";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_unique" UNIQUE USING INDEX "series_unique";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."series" validate CONSTRAINT "series_user_id_fkey";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_at_check" CHECK (is_finite (at)) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_at_check";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_context_id_fkey";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_pomodoro_check" CHECK (((pomodoro IS NULL) OR (pomodoro > 0))) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_pomodoro_check";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_user_id_fkey";

ALTER TABLE "public"."tag"
    ADD CONSTRAINT "tag_note_id_fkey" FOREIGN KEY (note_id) REFERENCES note (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."tag" validate CONSTRAINT "tag_note_id_fkey";

ALTER TABLE "public"."tag"
    ADD CONSTRAINT "tag_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."tag" validate CONSTRAINT "tag_user_id_fkey";

ALTER TABLE "public"."tag"
    ADD CONSTRAINT "tag_user_id_note_id_emoji_key" UNIQUE USING INDEX "tag_user_id_note_id_emoji_key";

CREATE OR REPLACE VIEW "public"."context_x" AS
SELECT
    c2.id,
    cu.user_id,
    c2.created_at,
    GREATEST (cs.modified_at, cu.modified_at, c2.modified_at) AS modified_at,
    c2.name,
    replace_parent_path (c1.path, c2.path, COALESCE(cu.path, c1.path)) AS path,
    COALESCE(cs."order", (((EXTRACT(epoch FROM CURRENT_TIMESTAMP) * (1000)::numeric))::double precision * (10)::double precision)) AS "order",
    COALESCE(cs.pomodoro, 25) AS pomodoro
FROM (((context_user cu
            JOIN context c1 ON (cu.context_id = c1.id))
        JOIN context c2 ON (c1.path @> c2.path))
    LEFT JOIN context_settings cs ON (((cs.user_id = cu.user_id)
                AND (c2.id = cs.context_id))));

CREATE OR REPLACE VIEW "public"."event_invitees" AS
SELECT
    i.event_id,
    (count(i.email))::integer AS invitee_count,
    (count(i.email) FILTER (WHERE (i.response = 'accepted'::event_response)))::integer AS attendee_count,
array_agg(i.email) AS invitees,
array_agg(DISTINCT d.name) AS invitee_domains,
COALESCE(array_agg(DISTINCT d.organization_id) FILTER (WHERE (d.organization_id IS NOT NULL)), ARRAY[]::bigint[]) AS invitee_organization_ids,
(count(i.email) FILTER (WHERE (d.organization_id IS NULL)) > 0) AS freemail_invitees,
calc_meeting_size ((count(i.email))::integer) AS size
FROM (invitee i
    LEFT JOIN DOMAIN d ON ((d.name = get_domain (i.email))))
GROUP BY
    i.event_id;

CREATE OR REPLACE VIEW "public"."event_x" AS
WITH event_x1 AS (
    SELECT
        e_1.id,
        e_1.user_id,
        e_1.name,
        CASE WHEN calc_all_day (e_1.at) THEN
            tstzrange(timezone(user_timezone (), timezone('UTC'::text, lower(e_1.at))), timezone(user_timezone (), timezone('UTC'::text, upper(e_1.at))), '[)'::text)
        ELSE
            e_1.at
        END AS at,
        c.account_id,
        e_1.calendar_id,
        e_1.provider_id,
        COALESCE(e_1.series, e_1.provider_id) AS series,
        e_1.created_at,
        e_1.status,
        e_1.provider_link,
        e_1.summary,
        e_1.description,
        e_1.visibility,
        e_1.availability,
        e_1.conferencing_url,
        e_1.organizer_email,
        e_1.response,
        calc_seconds (e_1.at) AS seconds,
        CASE WHEN (EXTRACT(epoch FROM (upper(e_1.at) - lower(e_1.at))) >= (((60 * 60) * 23))::numeric) THEN
            (timezone(user_timezone (), timezone('UTC'::text, lower(e_1.at))))::date
        ELSE
            ((lower(e_1.at) AT TIME ZONE user_timezone ()))::date
        END AS day,
        (a.email = e_1.organizer_email) AS initiated,
        calc_all_day (e_1.at) AS all_day,
        calc_event_type (e_1.at, e_1.availability, COALESCE(e_1.response, 'tentative'::event_response), ((i.invitee_count > 1)
            OR e_1.invitees_hidden)) AS type,
        ((d.organization_id IS NOT NULL)
        AND (i.freemail_invitees
            OR (NOT (d.organization_id = ALL (i.invitee_organization_ids))))) AS external,
        e_1.invitees_hidden,
        (e_1.series IS NOT NULL) AS recurring,
        calc_notice (e_1.created_at, e_1.at) AS notice,
        calc_speedy (e_1.at) AS speedy,
        calc_rounded_length (e_1.at) AS rounded_length,
        s_1.embedding,
        i.attendee_count,
        i.invitee_count,
        i.invitees,
        i.invitee_domains,
        i.size
    FROM (((((event e_1
                    LEFT JOIN calendar c ON (e_1.calendar_id = c.id))
                LEFT JOIN account a ON (c.account_id = a.id))
            LEFT JOIN DOMAIN d ON ((d.name = get_domain (a.email))))
        LEFT JOIN series s_1 ON (((s_1.user_id = e_1.user_id)
                    AND (s_1.series = e_1.series))))
        LEFT JOIN event_invitees i ON (e_1.id = i.event_id))
    WHERE ((e_1.calendar_id IS NULL)
        OR (c.enabled = TRUE)))
SELECT
    e.id,
    e.user_id,
    e.name,
    e.at,
    e.account_id,
    e.calendar_id,
    e.provider_id,
    e.series,
    e.created_at,
    e.status,
    e.provider_link,
    e.summary,
    e.description,
    e.visibility,
    e.availability,
    e.conferencing_url,
    e.organizer_email,
    e.response,
    e.seconds,
    e.day,
    e.initiated,
    e.all_day,
    e.type,
    e.external,
    e.invitees_hidden,
    e.recurring,
    e.notice,
    e.speedy,
    e.rounded_length,
    e.embedding,
    e.attendee_count,
    e.invitee_count,
    e.invitees,
    e.invitee_domains,
    e.size,
    ctx.id AS context_id,
    ctx.path AS context_path
FROM ((event_x1 e
    LEFT JOIN LATERAL (
        SELECT
            series.context_id
        FROM
            series
        WHERE ((series.user_id = e.user_id)
            AND (series.context_id IS NOT NULL))
    ORDER BY
        (series.series = e.series) DESC,
        (series.invitees = e.invitees) DESC,
        (series.embedding <-> e.embedding) DESC
    LIMIT 1) s ON (TRUE))
    LEFT JOIN context ctx ON (ctx.id = s.context_id));

CREATE OR REPLACE VIEW "public"."balance" AS
SELECT
    COALESCE(ex.user_id, s.user_id) AS user_id,
    COALESCE(ex.day, s.day) AS day,
    COALESCE(ex.context_id, s.context_id) AS context_id,
    ex.type,
    COALESCE((COALESCE(ex.events, (0)::bigint) + COALESCE(s.events, (0)::bigint))) AS events,
    COALESCE((COALESCE(ex.seconds, (0)::bigint) + COALESCE(s.seconds, 0))) AS seconds
FROM ((
        SELECT
            event_x.user_id,
            event_x.day,
            event_x.context_id,
            'accepted'::text AS type,
            COALESCE(count(*) FILTER (WHERE ((event_x.response <> 'declined'::event_response)
                AND (event_x.response <> 'tentative'::event_response)
            AND (event_x.response IS NOT NULL))), (0)::bigint) AS events,
            COALESCE(sum(event_x.seconds) FILTER (WHERE ((event_x.response <> 'declined'::event_response)
                AND (event_x.response <> 'tentative'::event_response)
            AND (event_x.response IS NOT NULL))), (0)::bigint) AS seconds
        FROM
            event_x
        WHERE ((event_x.status <> 'cancelled'::event_status)
            AND (event_x.all_day = FALSE))
    GROUP BY
        event_x.user_id,
        event_x.day,
        event_x.context_id
    UNION ALL
    SELECT
        event_x.user_id,
        event_x.day,
        event_x.context_id,
        'tentative'::text AS type,
        COALESCE(count(*) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
            OR (event_x.response IS NULL))), (0)::bigint) AS events,
        COALESCE(sum(event_x.seconds) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
            OR (event_x.response IS NULL))), (0)::bigint) AS seconds
    FROM
        event_x
    WHERE ((event_x.status <> 'cancelled'::event_status)
        AND (event_x.all_day = FALSE))
GROUP BY
    event_x.user_id,
    event_x.day,
    event_x.context_id
UNION ALL
SELECT
    event_x.user_id,
    event_x.day,
    event_x.context_id,
    'declined'::text AS type,
    COALESCE(count(*) FILTER (WHERE (event_x.response = 'declined'::event_response)), (0)::bigint) AS events,
    COALESCE(sum(event_x.seconds) FILTER (WHERE (event_x.response = 'declined'::event_response)), (0)::bigint) AS seconds
FROM
    event_x
WHERE ((event_x.status <> 'cancelled'::event_status)
    AND (event_x.all_day = FALSE))
GROUP BY
    event_x.user_id,
    event_x.day,
    event_x.context_id) ex
    FULL JOIN (
        SELECT
            session.user_id,
            ((lower(session.at) AT TIME ZONE user_timezone ()))::date AS day,
            session.context_id,
            'accepted'::text AS type,
            count(*) AS events,
            (sum((EXTRACT(epoch FROM (upper(session.at) - lower(session.at))) / (60)::numeric)))::integer AS seconds
        FROM
            session
        GROUP BY
            session.user_id,
            (((lower(session.at) AT TIME ZONE user_timezone ()))::date),
            session.context_id) s ON (((ex.user_id = s.user_id)
                AND (ex.day = s.day)
                AND (ex.context_id = s.context_id)
                AND (ex.type = s.type))));

CREATE OR REPLACE FUNCTION public.calendar (event_x)
    RETURNS SETOF calendar
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        calendar.*
    FROM
        calendar
    WHERE
        calendar.id = $1.calendar_id
$function$;

CREATE OR REPLACE FUNCTION public.invitee (event_x)
    RETURNS SETOF invitee
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        *
    FROM
        invitee
    WHERE
        event_id = $1.id
$function$;

CREATE OR REPLACE VIEW "public"."gap" AS
SELECT
    gap.user_id,
    gap.day,
    (gap.at * tstzrange(((gap.day + work_day_start ()) AT TIME ZONE user_timezone ()), ((gap.day + work_day_end ()) AT TIME ZONE user_timezone ()), '[]'::text)) AS at,
    calc_seconds ((gap.at * tstzrange(((gap.day + work_day_start ()) AT TIME ZONE user_timezone ()), ((gap.day + work_day_end ()) AT TIME ZONE user_timezone ()), '[]'::text))) AS seconds
FROM (
    SELECT
        e.user_id,
        e.day,
        CASE WHEN ((EXTRACT(isodow FROM e.day) <= (5)::numeric)
            AND (max(upper(e.at)) OVER start_window < lower(e.at))) THEN
            tstzrange(max(upper(e.at)) OVER start_window, lower(e.at), '[)'::text)
        ELSE
            NULL::tstzrange
        END AS at
    FROM (
        SELECT
            event_x.user_id,
            event_x.day,
            event_x.at
        FROM
            event_x
        WHERE ((event_x.type = 'meeting'::event_type)
            AND (event_x.status <> 'cancelled'::event_status)
            AND (event_x.response = 'accepted'::event_response))
    UNION
    SELECT DISTINCT
        auth.uid () AS id,
        days.day,
        tstzrange(((days.day + '1 day'::interval) AT TIME ZONE user_timezone ()), ((days.day + '1 day'::interval) AT TIME ZONE user_timezone ()), '[]'::text) AS at
    FROM (
        SELECT
            (generate_series(((min(lower(event.at)))::date)::timestamp with time zone, ((max(upper(event.at)))::date)::timestamp with time zone, '1 day'::interval))::date AS day
        FROM
            event) days) e
WINDOW start_window AS (PARTITION BY e.user_id ORDER BY (lower(e.at)),
    (upper(e.at))
    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)) gap
WHERE (gap.at IS NOT NULL);

CREATE OR REPLACE VIEW "public"."gap_daily" AS
SELECT
    gap.user_id,
    gap.day,
    sum(gap.seconds) AS total,
    sum(gap.seconds) FILTER (WHERE (gap.seconds >= 60)) AS focus
FROM
    gap
GROUP BY
    gap.user_id,
    gap.day;

CREATE OR REPLACE VIEW "public"."gap_monthly" AS
SELECT
    gap.user_id,
    (date_trunc('month'::text, (gap.day)::timestamp with time zone))::date AS month,
    sum(gap.seconds) AS total,
    sum(gap.seconds) FILTER (WHERE (gap.seconds >= 60)) AS focus
FROM
    gap
GROUP BY
    gap.user_id,
    ((date_trunc('month'::text, (gap.day)::timestamp with time zone))::date);

CREATE OR REPLACE VIEW "public"."insight" AS
SELECT
    e.user_id,
    e.day,
    text2ltree (min(ltree2text (e.context_path))) AS context_path,
    e.type,
    e.response,
    nv.name,
    nv.value,
    (count(*))::integer AS count,
    (sum(e.seconds))::integer AS seconds
FROM (event_x e
    CROSS JOIN LATERAL (
        VALUES ('Total'::text, NULL::text),
            ('Length'::text, (e.rounded_length)::text),
            ('Size'::text, e.size),
            ('Organizer'::text, CASE WHEN e.initiated THEN
                    'You'::text
                ELSE
                    e.organizer_email
                END),
            ('External'::text, CASE WHEN (e.external = TRUE) THEN
                    'External'::text
                ELSE
                    'Internal'::text
                END),
            ('Recurring'::text, CASE WHEN e.recurring THEN
                    'Recurring'::text
                ELSE
                    'Ad hoc'::text
                END),
            ('Notice'::text, CASE WHEN (e.notice < 12) THEN
                    '< 12 hours'::text
                WHEN (e.notice < 24) THEN
                    '< 24 hours'::text
                WHEN (e.notice < (24 * 7)) THEN
                    '< week'::text
                ELSE
                    '> week'::text
                END)) nv (name, value))
WHERE (e.status <> 'cancelled'::event_status)
GROUP BY
    e.user_id,
    e.day,
    e.context_path,
    e.type,
    e.response,
    nv.name,
    nv.value;

CREATE POLICY "Users can read their accounts" ON "public"."account" AS permissive
    FOR SELECT TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can read/write their budgets" ON "public"."budget" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can view their own calendars" ON "public"."calendar" AS permissive
    FOR SELECT TO authenticated
        USING ((account_id IN (
            SELECT
                account.id
            FROM
                account)));

CREATE POLICY "Users can view their contact" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can access their contexts" ON "public"."context" AS permissive
    FOR SELECT TO authenticated
        USING (can_access_context (id));

CREATE POLICY "Users can create new contexts in their contexts" ON "public"."context" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK (can_access_context (parent_path (path)));

CREATE POLICY "Users can create new root contexts" ON "public"."context" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK ((nlevel (path) = 1));

CREATE POLICY "Users can update their contexts" ON "public"."context" AS permissive
    FOR UPDATE TO authenticated
        USING (can_access_context (id))
        WITH CHECK (((nlevel (path) = 1) OR can_access_context (parent_path (path))));

CREATE POLICY "Users can read/write their context settings" ON "public"."context_settings" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can see who shares their contexts" ON "public"."context_user" AS permissive
    FOR SELECT TO authenticated
        USING (((user_id = auth.uid ()) OR can_access_context (context_id)));

CREATE POLICY "Everyone can view all domains" ON "public"."domain" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "Users can edit their own events" ON "public"."event" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can read all embeddings" ON "public"."event" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "internal_admin can access all invitations" ON "public"."invitation" AS permissive
    FOR ALL TO internal_admin
        USING (TRUE);

CREATE POLICY "Users can edit their invitees for their events" ON "public"."invitee" AS permissive
    FOR ALL TO authenticated
        USING ((event_id IN (
            SELECT
                event.id
            FROM
                event)));

CREATE POLICY "Users can edit their notes" ON "public"."note" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Everyone can view all organizations" ON "public"."organization" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "Users can edit their own series" ON "public"."series" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can edit their sessions" ON "public"."session" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "internal_admin can edit the wailist" ON "public"."waitlist" AS permissive
    FOR ALL TO internal_admin
        USING (TRUE);

CREATE TRIGGER on_account_created
    AFTER INSERT ON public.account
    FOR EACH ROW
    EXECUTE FUNCTION insert_email_domain ();

CREATE TRIGGER set_account_modified_at
    BEFORE UPDATE ON public.account
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_budget_modified_at
    BEFORE UPDATE ON public.budget
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_calendar_modified_at
    BEFORE UPDATE ON public.calendar
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER on_contact_created
    AFTER INSERT ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION insert_email_domain ();

CREATE TRIGGER context_insert_trigger
    AFTER INSERT ON public.context
    FOR EACH ROW
    EXECUTE FUNCTION insert_context_user ();

CREATE TRIGGER set_context_created_by
    BEFORE INSERT ON public.context
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

CREATE TRIGGER set_context_modified_at
    BEFORE UPDATE ON public.context
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_context_settings_modified_at
    BEFORE UPDATE ON public.context_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_context_user_modified_at
    BEFORE UPDATE ON public.context_user
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER insert_context_x
    INSTEAD OF INSERT ON public.context_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_context_x_insert ();

CREATE TRIGGER update_context_x
    INSTEAD OF UPDATE ON public.context_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_context_x_update ();

CREATE TRIGGER set_event_modified_at
    BEFORE UPDATE ON public.event
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER on_invitee_created
    AFTER INSERT ON public.invitee
    FOR EACH ROW
    EXECUTE FUNCTION insert_email_domain ();

CREATE TRIGGER set_note_modified_at
    BEFORE UPDATE ON public.note
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_series_modified_at
    BEFORE UPDATE ON public.series
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_session_modified_at
    BEFORE UPDATE ON public.session
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE OR REPLACE VIEW "public"."note_x" AS
SELECT
    note.id,
    note.created_at,
    note.modified_at,
    note.user_id,
    note.context_id,
    note.topic_id,
    note.body,
    note."order",
    note.root,
    note.private,
    context.path AS context_path,
    COALESCE(jsonb_object_agg(tag_users.emoji, tag_users.user_ids) FILTER (WHERE (tag_users.emoji IS NOT NULL)), '{}'::jsonb) AS tags
FROM ((note
    LEFT JOIN context ON (note.context_id = context.id))
    LEFT JOIN (
        SELECT
            tag.note_id,
            tag.emoji,
            array_agg(tag.user_id ORDER BY tag.user_id) AS user_ids
        FROM
            tag
        GROUP BY
            tag.note_id,
            tag.emoji) tag_users ON (note.id = tag_users.note_id))
GROUP BY
    note.id,
    context.path;

CREATE OR REPLACE VIEW "public"."sync_admin" AS
SELECT
    min(a.email) AS email,
    min(a.id) AS account_id,
    ((array_agg(a.credentials))[0] -> 'provider'::text) AS provider,
    c.provider_id AS calendar_provider_id,
    c.created_at AS first_synced_at,
    c.full_sync_at,
    c.synced_at,
    c.sync_error AS error,
    CASE WHEN ((c.full_sync_at IS NULL)
        OR (c.sync_error IS NOT NULL)) THEN
        NULL::numeric
    ELSE
        round(EXTRACT(epoch FROM (COALESCE(c.full_sync_at, now()) - c.full_sync_started_at)))
    END AS sync_seconds,
    count(e.id) AS event_count
FROM ((account a
    LEFT JOIN calendar c ON (c.account_id = a.id))
    LEFT JOIN event e ON (e.calendar_id = c.id))
GROUP BY
    c.id;

CREATE OR REPLACE VIEW "public"."waitlist_admin" AS
SELECT
    min(w.id) AS id,
    min(w.created_at) AS created_at,
    min(w.email) AS email,
    CASE WHEN (min(c.sync_error) IS NOT NULL) THEN
        'sync_error'::text
    WHEN (min(w.activated_at) IS NOT NULL) THEN
        'active'::text
    WHEN (count(*) FILTER (WHERE ((a.credentials -> 'refresh_token'::text) IS NOT NULL)) > 0) THEN
        'synced'::text
    ELSE
        'waitlisted'::text
    END AS status,
    array_agg(DISTINCT a.email) FILTER (WHERE (a.email IS NOT NULL)) AS sync_accounts,
array_agg(c.sync_error) FILTER (WHERE (c.sync_error IS NOT NULL)) AS sync_error,
((array_agg(a.credentials))[0] -> 'provider'::text) AS provider,
w.invitation,
count(e.id) AS event_count
FROM (((waitlist w
        LEFT JOIN account a ON (((w.email = a.email)
                    AND (a.credentials IS NOT NULL))))
    LEFT JOIN calendar c ON (c.account_id = a.id))
    LEFT JOIN event e ON (e.calendar_id = c.id))
GROUP BY
    w.id;

ALTER VIEW note_x SET (security_invoker = TRUE);

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_invitees" SET (security_invoker = TRUE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."context_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

