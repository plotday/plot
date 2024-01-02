CREATE SCHEMA IF NOT EXISTS "extensions";

CREATE EXTENSION IF NOT EXISTS "btree_gist" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "ltree" WITH SCHEMA "extensions";

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
    RETURN EXTRACT(DOW FROM lower(p_week)) = 0
        AND upper(p_week) - lower(p_week) = 7;
END;
$function$;

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

CREATE TYPE "public"."event_availability" AS enum (
    'busy',
    'away',
    'focus',
    'free'
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
    "user_id" uuid NOT NULL,
    "domain_id" bigint,
    "credentials" jsonb,
    "provider" provider NOT NULL,
    "email" text,
    "contact_sync_state" jsonb
);

ALTER TABLE "public"."account" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."activity" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "name" text NOT NULL,
    "path" ltree NOT NULL
);

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."budget" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "activity_id" bigint,
    "week" daterange,
    "order" text,
    "budget" integer
);

ALTER TABLE "public"."budget" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."calendar" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
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
    "is_self" boolean NOT NULL DEFAULT FALSE,
    "email" text NOT NULL,
    "name" text,
    "domain_id" bigint,
    "avatar_url" text
);

ALTER TABLE "public"."contact" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."domain" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "domain" text NOT NULL,
    "organization_id" bigint
);

ALTER TABLE "public"."domain" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."event" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "calendar_id" bigint,
    "provider_id" text NOT NULL,
    "series" text,
    "name" text,
    "status" event_status NOT NULL DEFAULT 'confirmed' ::event_status,
    "at" tstzrange NOT NULL,
    "provider_link" text,
    "summary" text,
    "description" text,
    "visibility" event_visibility NOT NULL DEFAULT 'normal' ::event_visibility,
    "availability" event_availability NOT NULL DEFAULT 'busy' ::event_availability,
    "conferencing_url" text,
    "organizer_email" text,
    "sequence" integer NOT NULL DEFAULT 1,
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
    "event_id" bigint,
    "email" text NOT NULL,
    "response" event_response,
    "is_optional" boolean NOT NULL DEFAULT FALSE
);

ALTER TABLE "public"."invitee" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."note" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "activity_id" bigint,
    "body" text NOT NULL
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

CREATE TABLE "public"."rule" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "series" text,
    "name" text,
    "invitees" text[],
    "invitee_domain" text,
    "calendar_id" bigint,
    "internal" event_internal,
    "type" event_type,
    "activity_id" bigint
);

ALTER TABLE "public"."rule" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."time" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "activity_id" bigint,
    "at" tstzrange NOT NULL
);

ALTER TABLE "public"."time" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."waitlist" (
    "id" bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "email" text NOT NULL,
    "invitation" text,
    "activated_at" timestamp with time zone
);

ALTER TABLE "public"."waitlist" ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX account_pkey ON public.account USING btree (id);

CREATE INDEX account_user_id_idx ON public.account USING btree (user_id);

CREATE INDEX activity_path_idx ON public.activity USING gist (user_id, path);

CREATE UNIQUE INDEX activity_pkey ON public.activity USING btree (id);

CREATE UNIQUE INDEX budget_pkey ON public.budget USING btree (id);

CREATE UNIQUE INDEX budget_user_activity_week_unique ON public.budget USING btree (user_id, activity_id, week) NULLS NOT DISTINCT;

CREATE INDEX calendar_account_id_idx ON public.calendar USING btree (account_id);

CREATE UNIQUE INDEX calendar_account_provider_id_unique ON public.calendar USING btree (account_id, provider_id);

CREATE UNIQUE INDEX calendar_pkey ON public.calendar USING btree (id);

CREATE UNIQUE INDEX calendar_provider_id_unique ON public.raw_event USING btree (calendar_id, provider_id);

CREATE UNIQUE INDEX contact_pkey ON public.contact USING btree (id);

CREATE UNIQUE INDEX contact_user_email_unique ON public.contact USING btree (user_id, email) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX domain_domain_key ON public.domain USING btree (DOMAIN);

CREATE UNIQUE INDEX domain_pkey ON public.domain USING btree (id);

CREATE INDEX event_at_idx ON public.event USING spgist (at);

CREATE UNIQUE INDEX event_calendar_provider_id_unique ON public.event USING btree (calendar_id, provider_id) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX event_pkey ON public.event USING btree (id);

CREATE UNIQUE INDEX invitation_code_key ON public.invitation USING btree (code);

CREATE UNIQUE INDEX invitation_pkey ON public.invitation USING btree (id);

CREATE UNIQUE INDEX invitee_event_email_unique ON public.invitee USING btree (event_id, email);

CREATE INDEX invitee_event_id_idx ON public.invitee USING btree (event_id);

CREATE UNIQUE INDEX note_pkey ON public.note USING btree (id);

CREATE UNIQUE INDEX organization_pkey ON public.organization USING btree (id);

CREATE UNIQUE INDEX raw_event_pkey ON public.raw_event USING btree (id);

CREATE UNIQUE INDEX rule_pkey ON public.rule USING btree (id);

CREATE UNIQUE INDEX rule_unique ON public.rule USING btree (user_id, series, name, invitees, invitee_domain, calendar_id, internal, type) NULLS NOT DISTINCT;

CREATE INDEX rule_user_id_key ON public.rule USING btree (user_id);

CREATE INDEX time_at_idx ON public."time" USING spgist (at);

CREATE UNIQUE INDEX time_pkey ON public."time" USING btree (id);

CREATE UNIQUE INDEX user_path_unique ON public.activity USING btree (user_id, path);

CREATE UNIQUE INDEX waitlist_pkey ON public.waitlist USING btree (id);

ALTER TABLE "public"."account"
    ADD CONSTRAINT "account_pkey" PRIMARY KEY USING INDEX "account_pkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_pkey" PRIMARY KEY USING INDEX "activity_pkey";

ALTER TABLE "public"."budget"
    ADD CONSTRAINT "budget_pkey" PRIMARY KEY USING INDEX "budget_pkey";

ALTER TABLE "public"."calendar"
    ADD CONSTRAINT "calendar_pkey" PRIMARY KEY USING INDEX "calendar_pkey";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_pkey" PRIMARY KEY USING INDEX "contact_pkey";

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

ALTER TABLE "public"."rule"
    ADD CONSTRAINT "rule_pkey" PRIMARY KEY USING INDEX "rule_pkey";

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_pkey" PRIMARY KEY USING INDEX "time_pkey";

ALTER TABLE "public"."waitlist"
    ADD CONSTRAINT "waitlist_pkey" PRIMARY KEY USING INDEX "waitlist_pkey";

ALTER TABLE "public"."account"
    ADD CONSTRAINT "account_domain_id_fkey" FOREIGN KEY (domain_id) REFERENCES DOMAIN (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."account" validate CONSTRAINT "account_domain_id_fkey";

ALTER TABLE "public"."account"
    ADD CONSTRAINT "account_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."account" validate CONSTRAINT "account_user_id_fkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_user_id_fkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "user_path_unique" UNIQUE USING INDEX "user_path_unique";

ALTER TABLE "public"."budget"
    ADD CONSTRAINT "budget_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."budget" validate CONSTRAINT "budget_activity_id_fkey";

ALTER TABLE "public"."budget"
    ADD CONSTRAINT "budget_user_activity_week_unique" UNIQUE USING INDEX "budget_user_activity_week_unique";

ALTER TABLE "public"."budget"
    ADD CONSTRAINT "budget_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."budget" validate CONSTRAINT "budget_user_id_fkey";

ALTER TABLE "public"."budget"
    ADD CONSTRAINT "budget_week_check" CHECK (is_week (week)) NOT valid;

ALTER TABLE "public"."budget" validate CONSTRAINT "budget_week_check";

ALTER TABLE "public"."calendar"
    ADD CONSTRAINT "calendar_account_id_fkey" FOREIGN KEY (account_id) REFERENCES account (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."calendar" validate CONSTRAINT "calendar_account_id_fkey";

ALTER TABLE "public"."calendar"
    ADD CONSTRAINT "calendar_account_provider_id_unique" UNIQUE USING INDEX "calendar_account_provider_id_unique";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_domain_id_fkey" FOREIGN KEY (domain_id) REFERENCES DOMAIN (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_domain_id_fkey";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_email_check" CHECK (is_lower (email)) NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_email_check";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_email_unique" UNIQUE USING INDEX "contact_user_email_unique";

ALTER TABLE "public"."contact"
    ADD CONSTRAINT "contact_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."contact" validate CONSTRAINT "contact_user_id_fkey";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_domain_check" CHECK (is_lower (DOMAIN)) NOT valid;

ALTER TABLE "public"."domain" validate CONSTRAINT "domain_domain_check";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_domain_key" UNIQUE USING INDEX "domain_domain_key";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES organization (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."domain" validate CONSTRAINT "domain_organization_id_fkey";

ALTER TABLE "public"."event"
    ADD CONSTRAINT "event_calendar_id_fkey" FOREIGN KEY (calendar_id) REFERENCES calendar (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."event" validate CONSTRAINT "event_calendar_id_fkey";

ALTER TABLE "public"."event"
    ADD CONSTRAINT "event_calendar_provider_id_unique" UNIQUE USING INDEX "event_calendar_provider_id_unique";

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
    ADD CONSTRAINT "note_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."note" validate CONSTRAINT "note_activity_id_fkey";

ALTER TABLE "public"."note"
    ADD CONSTRAINT "note_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."note" validate CONSTRAINT "note_user_id_fkey";

ALTER TABLE "public"."raw_event"
    ADD CONSTRAINT "calendar_provider_id_unique" UNIQUE USING INDEX "calendar_provider_id_unique";

ALTER TABLE "public"."raw_event"
    ADD CONSTRAINT "raw_event_calendar_id_fkey" FOREIGN KEY (calendar_id) REFERENCES calendar (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."raw_event" validate CONSTRAINT "raw_event_calendar_id_fkey";

ALTER TABLE "public"."rule"
    ADD CONSTRAINT "rule_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."rule" validate CONSTRAINT "rule_activity_id_fkey";

ALTER TABLE "public"."rule"
    ADD CONSTRAINT "rule_calendar_id_fkey" FOREIGN KEY (calendar_id) REFERENCES calendar (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."rule" validate CONSTRAINT "rule_calendar_id_fkey";

ALTER TABLE "public"."rule"
    ADD CONSTRAINT "rule_unique" UNIQUE USING INDEX "rule_unique";

ALTER TABLE "public"."rule"
    ADD CONSTRAINT "rule_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."rule" validate CONSTRAINT "rule_user_id_fkey";

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_activity_id_fkey";

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_at_check" CHECK (is_finite (at)) NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_at_check";

ALTER TABLE "public"."time"
    ADD CONSTRAINT "time_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."time" validate CONSTRAINT "time_user_id_fkey";

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

CREATE OR REPLACE FUNCTION public.budget (activity)
    RETURNS SETOF budget
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        *
    FROM
        budget
    WHERE
        activity_id = $1.id;
$function$;

CREATE OR REPLACE FUNCTION public.calc_all_day (at tstzrange)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
DECLARE
    minutes integer = calc_minutes (at);
BEGIN
    RETURN minutes >= 60 * 23;
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

CREATE OR REPLACE FUNCTION public.calc_minutes (at tstzrange)
    RETURNS integer
    LANGUAGE plpgsql
    IMMUTABLE
    AS $function$
BEGIN
    RETURN (round((EXTRACT(epoch FROM (upper(at) - lower(at))) / (60)::numeric)))::integer;
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
    minutes integer = calc_minutes (at);
BEGIN
    RETURN CASE WHEN minutes <= 20 THEN
        15
    WHEN minutes < 40 THEN
        30
    WHEN minutes < 50 THEN
        45
    WHEN minutes < 75 THEN
        60
    WHEN minutes < 101 THEN
        90
    WHEN minutes < 131 THEN
        120
    WHEN minutes < 161 THEN
        150
    WHEN minutes <= 180 THEN
        180
    WHEN minutes <= 300 THEN
        240
    WHEN minutes <= 420 THEN
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
    minutes integer = calc_minutes (at);
BEGIN
    RETURN minutes < 30
        OR (MOD(minutes, 30) >= 10
            AND MOD(minutes, 30) <= 15);
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

CREATE OR REPLACE FUNCTION public.extract_minutes (r tstzrange)
    RETURNS integer
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN round((EXTRACT(epoch FROM (upper(r) - lower(r))) / (60)::numeric))::integer;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_or_create_domain_id (email text)
    RETURNS bigint
    LANGUAGE plpgsql
    AS $function$
DECLARE
    domain_name text := lower(regexp_replace(split_part(email, '@', 2), '\s+', '', 'g'));
    domain_id bigint;
    org_id bigint;
BEGIN
    SELECT
        id INTO domain_id
    FROM
        public.domain
    WHERE
        "domain" = domain_name;
    IF FOUND THEN
        RETURN domain_id;
    ELSE
        INSERT INTO organization (name)
            VALUES (domain_name)
        RETURNING
            id INTO org_id;
        INSERT INTO public.domain (organization_id, "domain")
            VALUES (org_id, domain_name);
        RETURN domain_id;
    END IF;
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
    "event_id" bigint,
    "email" text,
    "response" event_response,
    "is_optional" boolean
);

CREATE OR REPLACE FUNCTION public.link_account_to_domain ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    IF NEW.email IS NULL THEN
        RETURN NEW;
    END IF;
    UPDATE
        public.account
    SET
        domain_id = (
            SELECT
                public.get_or_create_domain_id (NEW.email))
    WHERE
        id = NEW.id;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.link_contact_to_domain ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
BEGIN
    IF NEW.email IS NOT NULL THEN
        NEW.domain_id = (
            SELECT
                public.get_or_create_domain_id (NEW.email));
    END IF;
    RETURN NEW;
END
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
        domain.id = $1.domain_id
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
        domain.id = $1.domain_id
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

CREATE OR REPLACE VIEW "public"."sync_admin" AS
SELECT
    min(a.email) AS email,
    min(a.id) AS account_id,
    min(a.provider) AS provider,
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

CREATE OR REPLACE FUNCTION public.upsert_invitees (_event_ids bigint[], _invitees invitee_upsert[])
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
    RETURN COALESCE(auth.jwt () -> 'app_metadata' -> 'timezone', 'America/New_York');
END;
$function$;

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
array_agg(DISTINCT a.provider) FILTER (WHERE (a.provider IS NOT NULL)) AS provider,
w.invitation,
count(e.id) AS event_count
FROM (((waitlist w
        LEFT JOIN account a ON (((w.email = a.email)
                    AND (a.credentials IS NOT NULL))))
    LEFT JOIN calendar c ON (c.account_id = a.id))
    LEFT JOIN event e ON (e.calendar_id = c.id))
GROUP BY
    w.id;

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

CREATE OR REPLACE VIEW "public"."event_x" AS
WITH event_x1 AS (
    SELECT
        a.user_id,
        min(e_1.id) AS id,
        e_1.name,
        CASE WHEN calc_all_day (e_1.at) THEN
            tstzrange(timezone(user_timezone (), timezone('UTC'::text, lower(e_1.at))), timezone(user_timezone (), timezone('UTC'::text, upper(e_1.at))), '[)'::text)
        ELSE
            e_1.at
        END AS at,
        min(e_1.calendar_id) AS calendar_id,
        min(e_1.provider_id) AS provider_id,
        COALESCE(min(e_1.series), min(e_1.provider_id)) AS series,
        min(e_1.created_at) AS created_at,
        min(e_1.status) AS status,
        min(e_1.provider_link) AS provider_link,
        min(e_1.summary) AS summary,
        min(e_1.description) AS description,
        min(e_1.visibility) AS visibility,
        min(e_1.availability) AS availability,
        min(e_1.conferencing_url) AS conferencing_url,
        min(e_1.organizer_email) AS organizer_email,
        COALESCE(min(i.response) FILTER (WHERE (ct.is_self = TRUE)), 'tentative'::event_response) AS response,
        calc_minutes (e_1.at) AS minutes,
        (count(DISTINCT i.email) FILTER (WHERE (i.response = 'accepted'::event_response)))::integer AS attendee_count,
    (count(DISTINCT i.email))::integer AS invitee_count,
    CASE WHEN (EXTRACT(epoch FROM (upper(e_1.at) - lower(e_1.at))) >= (((60 * 60) * 23))::numeric) THEN
        (timezone(user_timezone (), timezone('UTC'::text, lower(e_1.at))))::date
    ELSE
        ((lower(e_1.at) AT TIME ZONE user_timezone ()))::date
    END AS day,
    COALESCE(bool_or(ct.is_self) FILTER (WHERE (ct.email = e_1.organizer_email)), FALSE) AS initiated,
    calc_all_day (e_1.at) AS all_day,
    calc_event_type (e_1.at, min(e_1.availability), COALESCE(min(i.response) FILTER (WHERE ct.is_self), 'tentative'::event_response), (((count(DISTINCT i.email))::integer > 1)
    OR bool_or(e_1.invitees_hidden))) AS type,
    calc_internal ((count(DISTINCT i.email))::integer, min(ct.domain_id) FILTER (WHERE ct.is_self), array_agg(DISTINCT ct.domain_id)) AS internal,
    array_agg(DISTINCT i.email ORDER BY i.email) AS invitees,
    array_agg(DISTINCT split_part(i.email, '@'::text, 2)
    ORDER BY (split_part(i.email, '@'::text, 2))) AS invitee_domains,
    bool_or(e_1.invitees_hidden) AS invitees_hidden,
    (min(e_1.series) IS NOT NULL) AS recurring,
    calc_notice (min(e_1.created_at), e_1.at) AS notice,
    calc_speedy (e_1.at) AS speedy,
    calc_rounded_length (e_1.at) AS rounded_length,
    calc_meeting_size ((count(DISTINCT i.email))::integer) AS size
FROM ((((event e_1
                JOIN calendar c ON (e_1.calendar_id = c.id))
            JOIN account a ON (c.account_id = a.id))
        JOIN invitee i ON (e_1.id = i.event_id))
    JOIN contact ct ON (((ct.user_id = a.user_id)
                AND (i.email = ct.email))))
WHERE (c.enabled = TRUE)
GROUP BY
    a.user_id,
    e_1.name,
    e_1.at
)
SELECT
    e.user_id,
    e.id,
    e.name,
    e.at,
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
    e.minutes,
    e.attendee_count,
    e.invitee_count,
    e.day,
    e.initiated,
    e.all_day,
    e.type,
    e.internal,
    e.invitees,
    e.invitee_domains,
    e.invitees_hidden,
    e.recurring,
    e.notice,
    e.speedy,
    e.rounded_length,
    e.size,
    act.id AS activity_id,
    act.path AS activity_path
FROM ((event_x1 e
    LEFT JOIN LATERAL (
        SELECT
            r_1.activity_id,
            ((((((
                CASE WHEN (r_1.series IS NOT NULL) THEN
                    64
                ELSE
                    0
                END + CASE WHEN (r_1.name IS NOT NULL) THEN
                    32
                ELSE
                    0
                END) + CASE WHEN (r_1.invitees IS NOT NULL) THEN
                16
            ELSE
                0
            END) + CASE WHEN (r_1.invitee_domain IS NOT NULL) THEN
            8
        ELSE
            0
        END) + CASE WHEN (r_1.calendar_id IS NOT NULL) THEN
        4
    ELSE
        0
    END) + CASE WHEN (r_1.internal IS NOT NULL) THEN
    2
ELSE
    0
END) + CASE WHEN (r_1.type IS NOT NULL) THEN
    1
ELSE
    0
END) AS priority
        FROM
            rule r_1
        WHERE ((e.user_id = r_1.user_id)
            AND ((r_1.series IS NULL)
                OR (e.series = r_1.series))
            AND ((r_1.name IS NULL)
                OR (e.name = r_1.name))
            AND ((r_1.invitees IS NULL)
                OR (e.invitees = r_1.invitees))
            AND ((r_1.invitee_domain IS NULL)
                OR (e.invitee_domains @> ARRAY[r_1.invitee_domain]))
            AND ((r_1.calendar_id IS NULL)
                OR (e.calendar_id = r_1.calendar_id))
            AND ((r_1.internal IS NULL)
                OR (e.internal = r_1.internal))
            AND ((r_1.type IS NULL)
                OR (e.type = r_1.type)))
    ORDER BY
        ((((((
                                CASE WHEN (r_1.series IS NOT NULL) THEN
                                    64
                                ELSE
                                    0
                                END + CASE WHEN (r_1.name IS NOT NULL) THEN
                                    32
                                ELSE
                                    0
                                END) + CASE WHEN (r_1.invitees IS NOT NULL) THEN
                                16
                            ELSE
                                0
                            END) + CASE WHEN (r_1.invitee_domain IS NOT NULL) THEN
                            8
                        ELSE
                            0
                        END) + CASE WHEN (r_1.calendar_id IS NOT NULL) THEN
                        4
                    ELSE
                        0
                    END) + CASE WHEN (r_1.internal IS NOT NULL) THEN
                    2
                ELSE
                    0
                END) + CASE WHEN (r_1.type IS NOT NULL) THEN
                1
            ELSE
                0
            END) DESC,
        r_1.created_at DESC
    LIMIT 1) r ON (TRUE))
    LEFT JOIN activity act ON (((e.user_id = act.user_id)
                AND (r.activity_id = act.id))));

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
    extract_minutes ((gap.at * tstzrange(((gap.day + work_day_start ()) AT TIME ZONE user_timezone ()), ((gap.day + work_day_end ()) AT TIME ZONE user_timezone ()), '[]'::text))) AS minutes
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
    sum(gap.minutes) AS total,
    sum(gap.minutes) FILTER (WHERE (gap.minutes >= 60)) AS focus
FROM
    gap
GROUP BY
    gap.user_id,
    gap.day;

CREATE OR REPLACE VIEW "public"."gap_monthly" AS
SELECT
    gap.user_id,
    (date_trunc('month'::text, (gap.day)::timestamp with time zone))::date AS month,
    sum(gap.minutes) AS total,
    sum(gap.minutes) FILTER (WHERE (gap.minutes >= 60)) AS focus
FROM
    gap
GROUP BY
    gap.user_id,
    ((date_trunc('month'::text, (gap.day)::timestamp with time zone))::date);

CREATE OR REPLACE VIEW "public"."insight" AS
SELECT
    e.user_id,
    e.day,
    text2ltree (min(ltree2text (e.activity_path))) AS activity_path,
    e.type,
    e.response,
    nv.name,
    nv.value,
    (count(*))::integer AS count,
    (sum(e.minutes))::integer AS minutes
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
            ('External'::text, CASE WHEN (e.internal = 'internal'::event_internal) THEN
                    'Interal'::text
                WHEN (e.internal = 'external'::event_internal) THEN
                    'External'::text
                ELSE
                    NULL::text
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
    e.activity_path,
    e.type,
    e.response,
    nv.name,
    nv.value;

CREATE OR REPLACE VIEW "public"."insight_weekly" AS
SELECT
    c.user_id,
    c.path,
    week_from_date (i.day) AS week,
    i.type,
    i.name,
    i.value,
    COALESCE(sum(i.count) FILTER (WHERE (i.response = 'accepted'::event_response)), (0)::bigint) AS count,
    COALESCE(sum(i.minutes) FILTER (WHERE (i.response = 'accepted'::event_response)), (0)::bigint) AS minutes,
    COALESCE(sum(i.count) FILTER (WHERE (i.response IS NULL)), (0)::bigint) AS pending_count,
    COALESCE(sum(i.minutes) FILTER (WHERE (i.response IS NULL)), (0)::bigint) AS pending_minutes
FROM (activity c
    LEFT JOIN insight i ON (c.path = i.activity_path))
GROUP BY
    c.user_id,
    c.path,
    (week_from_date (i.day)),
    i.type,
    i.name,
    i.value;

CREATE POLICY "Users can read their accounts" ON "public"."account" AS permissive
    FOR SELECT TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can read/write their activities" ON "public"."activity" AS permissive
    FOR ALL TO authenticated
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

CREATE POLICY "Everyone can view all domains" ON "public"."domain" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "Users can view their own events" ON "public"."event" AS permissive
    FOR SELECT TO authenticated
        USING ((calendar_id IN (
            SELECT
                calendar.id
            FROM
                calendar)));

CREATE POLICY "internal_admin can access all invitations" ON "public"."invitation" AS permissive
    FOR ALL TO internal_admin
        USING (TRUE);

CREATE POLICY "Users can view their invitees for their events" ON "public"."invitee" AS permissive
    FOR SELECT TO authenticated
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

CREATE POLICY "Users can edit their rules" ON "public"."rule" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "internal_admin can edit the wailist" ON "public"."waitlist" AS permissive
    FOR ALL TO internal_admin
        USING (TRUE);

CREATE TRIGGER on_account_created
    AFTER INSERT ON public.account
    FOR EACH ROW
    EXECUTE FUNCTION link_account_to_domain ();

CREATE TRIGGER on_contact_created
    BEFORE INSERT ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION link_contact_to_domain ();

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

ALTER VIEW insight_weekly SET (security_invoker = TRUE);

ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

-- Add personal email providers to prevent the creation of organizations
INSERT INTO "public"."domain" ("domain")
    VALUES ('gmail.com'),
    ('yahoo.com'),
    ('hotmail.com'),
    ('aol.com'),
    ('hotmail.co.uk'),
    ('hotmail.fr'),
    ('msn.com'),
    ('yahoo.fr'),
    ('wanadoo.fr'),
    ('orange.fr'),
    ('comcast.net'),
    ('yahoo.co.uk'),
    ('yahoo.com.br'),
    ('yahoo.co.in'),
    ('live.com'),
    ('rediffmail.com'),
    ('free.fr'),
    ('gmx.de'),
    ('web.de'),
    ('yandex.ru'),
    ('ymail.com'),
    ('libero.it'),
    ('outlook.com'),
    ('uol.com.br'),
    ('bol.com.br'),
    ('mail.ru'),
    ('cox.net'),
    ('hotmail.it'),
    ('sbcglobal.net'),
    ('sfr.fr'),
    ('live.fr'),
    ('verizon.net'),
    ('live.co.uk'),
    ('googlemail.com'),
    ('yahoo.es'),
    ('ig.com.br'),
    ('live.nl'),
    ('bigpond.com'),
    ('terra.com.br'),
    ('yahoo.it'),
    ('neuf.fr'),
    ('yahoo.de'),
    ('alice.it'),
    ('rocketmail.com'),
    ('att.net'),
    ('laposte.net'),
    ('facebook.com'),
    ('bellsouth.net'),
    ('yahoo.in'),
    ('hotmail.es'),
    ('charter.net'),
    ('yahoo.ca'),
    ('yahoo.com.au'),
    ('rambler.ru'),
    ('hotmail.de'),
    ('tiscali.it'),
    ('shaw.ca'),
    ('yahoo.co.jp'),
    ('sky.com'),
    ('earthlink.net'),
    ('optonline.net'),
    ('freenet.de'),
    ('t-online.de'),
    ('aliceadsl.fr'),
    ('virgilio.it'),
    ('home.nl'),
    ('qq.com'),
    ('telenet.be'),
    ('me.com'),
    ('yahoo.com.ar'),
    ('tiscali.co.uk'),
    ('yahoo.com.mx'),
    ('voila.fr'),
    ('gmx.net'),
    ('mail.com'),
    ('planet.nl'),
    ('tin.it'),
    ('live.it'),
    ('ntlworld.com'),
    ('arcor.de'),
    ('yahoo.co.id'),
    ('frontiernet.net'),
    ('hetnet.nl'),
    ('live.com.au'),
    ('yahoo.com.sg'),
    ('zonnet.nl'),
    ('club-internet.fr'),
    ('juno.com'),
    ('optusnet.com.au'),
    ('blueyonder.co.uk'),
    ('bluewin.ch'),
    ('skynet.be'),
    ('sympatico.ca'),
    ('windstream.net'),
    ('mac.com'),
    ('centurytel.net'),
    ('chello.nl'),
    ('live.ca'),
    ('aim.com'),
    ('bigpond.net.au'),
    ('icloud.com'),
    ('proton.me');

