
CREATE SCHEMA IF NOT EXISTS "extensions";

CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "btree_gist" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "ltree" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";

CREATE TYPE "public"."contact_upsert" AS (
	"calendar_id" bigint,
	"email" "text",
	"name" "text",
	"avatar_url" "text"
);

ALTER TYPE "public"."contact_upsert" OWNER TO "postgres";

CREATE TYPE "public"."event_availability" AS ENUM (
    'busy',
    'away',
    'focus',
    'free'
);

ALTER TYPE "public"."event_availability" OWNER TO "postgres";

CREATE TYPE "public"."event_ids" AS (
	"calendar_id" bigint,
	"provider_id" "text"
);

ALTER TYPE "public"."event_ids" OWNER TO "postgres";

CREATE TYPE "public"."event_internal" AS ENUM (
    'internal',
    'external'
);

ALTER TYPE "public"."event_internal" OWNER TO "postgres";

CREATE TYPE "public"."event_response" AS ENUM (
    'accepted',
    'declined',
    'tentative'
);

ALTER TYPE "public"."event_response" OWNER TO "postgres";

CREATE TYPE "public"."event_status" AS ENUM (
    'confirmed',
    'cancelled',
    'tentative'
);

ALTER TYPE "public"."event_status" OWNER TO "postgres";

CREATE TYPE "public"."event_type" AS ENUM (
    'meeting',
    'task',
    'note'
);

ALTER TYPE "public"."event_type" OWNER TO "postgres";

CREATE TYPE "public"."event_visibility" AS ENUM (
    'normal',
    'private',
    'confidential',
    'public',
    'personal'
);

ALTER TYPE "public"."event_visibility" OWNER TO "postgres";

CREATE TYPE "public"."invitee_upsert" AS (
	"event_id" bigint,
	"email" "text",
	"response" "public"."event_response",
	"is_optional" boolean
);

ALTER TYPE "public"."invitee_upsert" OWNER TO "postgres";

CREATE TYPE "public"."location_type" AS ENUM (
    'room',
    'address',
    'other'
);

ALTER TYPE "public"."location_type" OWNER TO "postgres";

CREATE TYPE "public"."meeting_size" AS ENUM (
    '1:1',
    'Small',
    'Medium',
    'Large',
    'XL',
    'XXL'
);

ALTER TYPE "public"."meeting_size" OWNER TO "postgres";

CREATE TYPE "public"."provider" AS ENUM (
    'google',
    'outlook'
);

ALTER TYPE "public"."provider" OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";

CREATE TABLE IF NOT EXISTS "public"."account" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "domain_id" bigint,
    "credentials" "jsonb",
    "email" "text" NOT NULL,
    "contact_sync_state" "jsonb"
);

ALTER TABLE "public"."account" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."calendar" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "account_id" bigint NOT NULL,
    "provider_id" "text" NOT NULL,
    "synced_dates" "tstzrange",
    "sync_state" "text",
    "watch_id" "text",
    "watch_secret" "text",
    "watch_expires_at" timestamp with time zone,
    "sequence" numeric DEFAULT '1'::numeric NOT NULL,
    "full_sync_at" timestamp with time zone,
    "synced_at" timestamp with time zone,
    "sync_error" "text",
    "full_sync_started_at" timestamp with time zone,
    "name" "text",
    "enabled" boolean DEFAULT false NOT NULL,
    "ready" boolean DEFAULT false NOT NULL
);

ALTER TABLE "public"."calendar" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."account"("public"."calendar") RETURNS SETOF "public"."account"
    LANGUAGE "sql" STABLE ROWS 1
    AS $_$
    SELECT
        account.*
    FROM
        account
    WHERE
        account.id = $1.account_id
$_$;

ALTER FUNCTION "public"."account"("public"."calendar") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."all_views_secure"() RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
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
$$;

ALTER FUNCTION "public"."all_views_secure"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."is_week"("p_week" "daterange") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
    RETURN p_week IS NULL
        OR EXTRACT(DOW FROM lower(p_week)) = 0
        AND upper(p_week) - lower(p_week) = 7;
END;
$$;

ALTER FUNCTION "public"."is_week"("p_week" "daterange") OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."activity" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "path" "extensions"."ltree" NOT NULL,
    "pomodoro" integer DEFAULT 25 NOT NULL
);

ALTER TABLE "public"."activity" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."budget" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "activity_id" bigint,
    "week" "daterange",
    "order" "text",
    "budget" integer,
    CONSTRAINT "budget_week_check" CHECK ("public"."is_week"("week"))
);

ALTER TABLE "public"."budget" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."budget"("public"."activity") RETURNS SETOF "public"."budget"
    LANGUAGE "sql" STABLE
    AS $_$
    SELECT
        *
    FROM
        budget
    WHERE
        activity_id = $1.id;
$_$;

ALTER FUNCTION "public"."budget"("public"."activity") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."budget_week"("user_id" "uuid", "week" "daterange") RETURNS TABLE("activity_id" bigint, "order" "text", "budget" integer)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        COALESCE(b.activity_id, b2.activity_id) AS activity_id,
        COALESCE(b.order, b2.order) AS "order",
        COALESCE(b.budget, b2.budget) AS budget
    FROM (
        SELECT
            *
        FROM
            budget bi
        WHERE
            bi.user_id = budget_week.user_id
            AND bi.week && budget_week.week) b
    FULL OUTER JOIN (
    SELECT
        *
    FROM
        budget bi
    WHERE
        bi.user_id = budget_week.user_id
        AND bi.week IS NULL) b2 ON b.activity_id = b2.activity_id
ORDER BY
    coalesce(b.order, b2.order);
END;
$$;

ALTER FUNCTION "public"."budget_week"("user_id" "uuid", "week" "daterange") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."calc_all_day"("at" "tstzrange") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
    minutes integer = calc_minutes (at);
BEGIN
    RETURN minutes >= 60 * 23;
END;
$$;

ALTER FUNCTION "public"."calc_all_day"("at" "tstzrange") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."calc_event_type"("at" "tstzrange", "availability" "public"."event_availability", "response" "public"."event_response", "has_invitees" boolean) RETURNS "public"."event_type"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
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
$$;

ALTER FUNCTION "public"."calc_event_type"("at" "tstzrange", "availability" "public"."event_availability", "response" "public"."event_response", "has_invitees" boolean) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."calc_internal"("invitee_count" integer, "user_domain" bigint, "domains" bigint[]) RETURNS "public"."event_internal"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
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
$$;

ALTER FUNCTION "public"."calc_internal"("invitee_count" integer, "user_domain" bigint, "domains" bigint[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."calc_meeting_size"("invitee_count" integer) RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
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
$$;

ALTER FUNCTION "public"."calc_meeting_size"("invitee_count" integer) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."calc_minutes"("at" "tstzrange") RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
    RETURN (round((EXTRACT(epoch FROM (upper(at) - lower(at))) / (60)::numeric)))::integer;
END;
$$;

ALTER FUNCTION "public"."calc_minutes"("at" "tstzrange") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."calc_notice"("created_at" timestamp with time zone, "at" "tstzrange") RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
    RETURN CASE WHEN created_at IS NULL THEN
        NULL
    WHEN created_at > LOWER(at) THEN
        0
    ELSE
        EXTRACT(EPOCH FROM (LOWER(at) - created_at))::integer
    END;
END;
$$;

ALTER FUNCTION "public"."calc_notice"("created_at" timestamp with time zone, "at" "tstzrange") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."calc_rounded_length"("at" "tstzrange") RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
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
$$;

ALTER FUNCTION "public"."calc_rounded_length"("at" "tstzrange") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."calc_speedy"("at" "tstzrange") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
DECLARE
    minutes integer = calc_minutes (at);
BEGIN
    RETURN minutes < 30
        OR (MOD(minutes, 30) >= 10
            AND MOD(minutes, 30) <= 15);
END;
$$;

ALTER FUNCTION "public"."calc_speedy"("at" "tstzrange") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."is_lower"("text") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    AS $_$
BEGIN
    RETURN $1 = lower($1);
END;
$_$;

ALTER FUNCTION "public"."is_lower"("text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."user_timezone"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN COALESCE((auth.jwt () -> 'app_metadata' -> 'timezone')::text, 'America/New_York');
END;
$$;

ALTER FUNCTION "public"."user_timezone"() OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."contact" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "is_self" boolean DEFAULT false NOT NULL,
    "email" "text" NOT NULL,
    "name" "text",
    "domain_id" bigint,
    "avatar_url" "text",
    CONSTRAINT "contact_email_check" CHECK ("public"."is_lower"("email"))
);

ALTER TABLE "public"."contact" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."event" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "calendar_id" bigint,
    "provider_id" "text" NOT NULL,
    "series" "text",
    "name" "text",
    "status" "public"."event_status" DEFAULT 'confirmed'::"public"."event_status" NOT NULL,
    "at" "tstzrange" NOT NULL,
    "provider_link" "text",
    "summary" "text",
    "description" "text",
    "visibility" "public"."event_visibility" DEFAULT 'normal'::"public"."event_visibility" NOT NULL,
    "availability" "public"."event_availability" DEFAULT 'busy'::"public"."event_availability" NOT NULL,
    "conferencing_url" "text",
    "organizer_email" "text",
    "sequence" integer DEFAULT 1 NOT NULL,
    "invitees_hidden" boolean DEFAULT false NOT NULL
);

ALTER TABLE "public"."event" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."invitee" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "event_id" bigint,
    "email" "text" NOT NULL,
    "response" "public"."event_response",
    "is_optional" boolean DEFAULT false NOT NULL,
    CONSTRAINT "invitee_email_check" CHECK ("public"."is_lower"("email"))
);

ALTER TABLE "public"."invitee" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."rule" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "series" "text",
    "name" "text",
    "invitees" "text"[],
    "invitee_domain" "text",
    "calendar_id" bigint,
    "internal" "public"."event_internal",
    "type" "public"."event_type",
    "activity_id" bigint,
    "account_id" bigint
);

ALTER TABLE "public"."rule" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."event_x" WITH ("security_invoker"='true') AS
 WITH "event_x1" AS (
         SELECT "a"."user_id",
            "min"("e_1"."id") AS "id",
            "e_1"."name",
                CASE
                    WHEN "public"."calc_all_day"("e_1"."at") THEN "tstzrange"("timezone"("public"."user_timezone"(), "timezone"('UTC'::"text", "lower"("e_1"."at"))), "timezone"("public"."user_timezone"(), "timezone"('UTC'::"text", "upper"("e_1"."at"))), '[)'::"text")
                    ELSE "e_1"."at"
                END AS "at",
            "min"("c"."account_id") AS "account_id",
            "min"("e_1"."calendar_id") AS "calendar_id",
            "min"("e_1"."provider_id") AS "provider_id",
            COALESCE("min"("e_1"."series"), "min"("e_1"."provider_id")) AS "series",
            "min"("e_1"."created_at") AS "created_at",
            "min"("e_1"."status") AS "status",
            "min"("e_1"."provider_link") AS "provider_link",
            "min"("e_1"."summary") AS "summary",
            "min"("e_1"."description") AS "description",
            "min"("e_1"."visibility") AS "visibility",
            "min"("e_1"."availability") AS "availability",
            "min"("e_1"."conferencing_url") AS "conferencing_url",
            "min"("e_1"."organizer_email") AS "organizer_email",
            COALESCE("min"("i"."response") FILTER (WHERE ("ct"."is_self" = true)), 'tentative'::"public"."event_response") AS "response",
            "public"."calc_minutes"("e_1"."at") AS "minutes",
            ("count"(DISTINCT "i"."email") FILTER (WHERE ("i"."response" = 'accepted'::"public"."event_response")))::integer AS "attendee_count",
            ("count"(DISTINCT "i"."email"))::integer AS "invitee_count",
                CASE
                    WHEN (EXTRACT(epoch FROM ("upper"("e_1"."at") - "lower"("e_1"."at"))) >= (((60 * 60) * 23))::numeric) THEN ("timezone"("public"."user_timezone"(), "timezone"('UTC'::"text", "lower"("e_1"."at"))))::"date"
                    ELSE (("lower"("e_1"."at") AT TIME ZONE "public"."user_timezone"()))::"date"
                END AS "day",
            COALESCE("bool_or"("ct"."is_self") FILTER (WHERE ("ct"."email" = "e_1"."organizer_email")), false) AS "initiated",
            "public"."calc_all_day"("e_1"."at") AS "all_day",
            "public"."calc_event_type"("e_1"."at", "min"("e_1"."availability"), COALESCE("min"("i"."response") FILTER (WHERE "ct"."is_self"), 'tentative'::"public"."event_response"), ((("count"(DISTINCT "i"."email"))::integer > 1) OR "bool_or"("e_1"."invitees_hidden"))) AS "type",
            "public"."calc_internal"(("count"(DISTINCT "i"."email"))::integer, "min"("ct"."domain_id") FILTER (WHERE "ct"."is_self"), "array_agg"(DISTINCT "ct"."domain_id")) AS "internal",
            "array_agg"(DISTINCT "i"."email" ORDER BY "i"."email") AS "invitees",
            "array_agg"(DISTINCT "split_part"("i"."email", '@'::"text", 2) ORDER BY ("split_part"("i"."email", '@'::"text", 2))) AS "invitee_domains",
            "bool_or"("e_1"."invitees_hidden") AS "invitees_hidden",
            ("min"("e_1"."series") IS NOT NULL) AS "recurring",
            "public"."calc_notice"("min"("e_1"."created_at"), "e_1"."at") AS "notice",
            "public"."calc_speedy"("e_1"."at") AS "speedy",
            "public"."calc_rounded_length"("e_1"."at") AS "rounded_length",
            "public"."calc_meeting_size"(("count"(DISTINCT "i"."email"))::integer) AS "size"
           FROM (((("public"."event" "e_1"
             JOIN "public"."calendar" "c" ON (("e_1"."calendar_id" = "c"."id")))
             JOIN "public"."account" "a" ON (("c"."account_id" = "a"."id")))
             JOIN "public"."invitee" "i" ON (("e_1"."id" = "i"."event_id")))
             JOIN "public"."contact" "ct" ON ((("ct"."user_id" = "a"."user_id") AND ("i"."email" = "ct"."email"))))
          WHERE ("c"."enabled" = true)
          GROUP BY "a"."user_id", "e_1"."name", "e_1"."at"
        )
 SELECT "e"."user_id",
    "e"."id",
    "e"."name",
    "e"."at",
    "e"."account_id",
    "e"."calendar_id",
    "e"."provider_id",
    "e"."series",
    "e"."created_at",
    "e"."status",
    "e"."provider_link",
    "e"."summary",
    "e"."description",
    "e"."visibility",
    "e"."availability",
    "e"."conferencing_url",
    "e"."organizer_email",
    "e"."response",
    "e"."minutes",
    "e"."attendee_count",
    "e"."invitee_count",
    "e"."day",
    "e"."initiated",
    "e"."all_day",
    "e"."type",
    "e"."internal",
    "e"."invitees",
    "e"."invitee_domains",
    "e"."invitees_hidden",
    "e"."recurring",
    "e"."notice",
    "e"."speedy",
    "e"."rounded_length",
    "e"."size",
    "act"."id" AS "activity_id",
    "act"."path" AS "activity_path"
   FROM (("event_x1" "e"
     LEFT JOIN LATERAL ( SELECT "r_1"."activity_id",
            (((((((
                CASE
                    WHEN ("r_1"."series" IS NOT NULL) THEN 128
                    ELSE 0
                END +
                CASE
                    WHEN ("r_1"."name" IS NOT NULL) THEN 64
                    ELSE 0
                END) +
                CASE
                    WHEN ("r_1"."invitees" IS NOT NULL) THEN 32
                    ELSE 0
                END) +
                CASE
                    WHEN ("r_1"."invitee_domain" IS NOT NULL) THEN 16
                    ELSE 0
                END) +
                CASE
                    WHEN ("r_1"."account_id" IS NOT NULL) THEN 8
                    ELSE 0
                END) +
                CASE
                    WHEN ("r_1"."calendar_id" IS NOT NULL) THEN 4
                    ELSE 0
                END) +
                CASE
                    WHEN ("r_1"."internal" IS NOT NULL) THEN 2
                    ELSE 0
                END) +
                CASE
                    WHEN ("r_1"."type" IS NOT NULL) THEN 1
                    ELSE 0
                END) AS "priority"
           FROM "public"."rule" "r_1"
          WHERE (("e"."user_id" = "r_1"."user_id") AND (("r_1"."series" IS NULL) OR ("e"."series" = "r_1"."series")) AND (("r_1"."name" IS NULL) OR ("e"."name" = "r_1"."name")) AND (("r_1"."invitees" IS NULL) OR ("e"."invitees" = "r_1"."invitees")) AND (("r_1"."invitee_domain" IS NULL) OR ("e"."invitee_domains" @> ARRAY["r_1"."invitee_domain"])) AND (("r_1"."account_id" IS NULL) OR ("e"."account_id" = "r_1"."account_id")) AND (("r_1"."calendar_id" IS NULL) OR ("e"."calendar_id" = "r_1"."calendar_id")) AND (("r_1"."internal" IS NULL) OR ("e"."internal" = "r_1"."internal")) AND (("r_1"."type" IS NULL) OR ("e"."type" = "r_1"."type")))
          ORDER BY (((((((
                CASE
                    WHEN ("r_1"."series" IS NOT NULL) THEN 128
                    ELSE 0
                END +
                CASE
                    WHEN ("r_1"."name" IS NOT NULL) THEN 64
                    ELSE 0
                END) +
                CASE
                    WHEN ("r_1"."invitees" IS NOT NULL) THEN 32
                    ELSE 0
                END) +
                CASE
                    WHEN ("r_1"."invitee_domain" IS NOT NULL) THEN 16
                    ELSE 0
                END) +
                CASE
                    WHEN ("r_1"."account_id" IS NOT NULL) THEN 8
                    ELSE 0
                END) +
                CASE
                    WHEN ("r_1"."calendar_id" IS NOT NULL) THEN 4
                    ELSE 0
                END) +
                CASE
                    WHEN ("r_1"."internal" IS NOT NULL) THEN 2
                    ELSE 0
                END) +
                CASE
                    WHEN ("r_1"."type" IS NOT NULL) THEN 1
                    ELSE 0
                END) DESC, "r_1"."created_at" DESC
         LIMIT 1) "r" ON (true))
     LEFT JOIN "public"."activity" "act" ON ((("e"."user_id" = "act"."user_id") AND ("r"."activity_id" = "act"."id"))));

ALTER TABLE "public"."event_x" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."calendar"("public"."event_x") RETURNS SETOF "public"."calendar"
    LANGUAGE "sql" STABLE ROWS 1
    AS $_$
    SELECT
        calendar.*
    FROM
        calendar
    WHERE
        calendar.id = $1.calendar_id
$_$;

ALTER FUNCTION "public"."calendar"("public"."event_x") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."calendars"("public"."account") RETURNS SETOF "public"."calendar"
    LANGUAGE "sql" STABLE
    AS $_$
    SELECT
        calendar.*
    FROM
        calendar
    WHERE
        calendar.account_id = $1.id
$_$;

ALTER FUNCTION "public"."calendars"("public"."account") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."cancel_events"("_events" "public"."event_ids"[]) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
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
$$;

ALTER FUNCTION "public"."cancel_events"("_events" "public"."event_ids"[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."contact"("public"."invitee") RETURNS SETOF "public"."contact"
    LANGUAGE "sql" STABLE ROWS 1
    AS $_$
    SELECT
        contact.*
    FROM
        contact
    WHERE
        contact.email = $1.email
$_$;

ALTER FUNCTION "public"."contact"("public"."invitee") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."extract_minutes"("r" "tstzrange") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN round((EXTRACT(epoch FROM (upper(r) - lower(r))) / (60)::numeric))::integer;
END;
$$;

ALTER FUNCTION "public"."extract_minutes"("r" "tstzrange") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."is_finite"("test" "tstzrange") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
BEGIN
    RETURN NOT (lower_inf(test)
        OR upper_inf(test));
END;
$$;

ALTER FUNCTION "public"."is_finite"("test" "tstzrange") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."link_account_to_domain"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;

ALTER FUNCTION "public"."link_account_to_domain"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."link_contact_to_domain"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    IF NEW.email IS NOT NULL THEN
        NEW.domain_id = (
            SELECT
                public.get_or_create_domain_id (NEW.email));
    END IF;
    RETURN NEW;
END
$$;

ALTER FUNCTION "public"."link_contact_to_domain"() OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."organization" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "name" "text" NOT NULL
);

ALTER TABLE "public"."organization" OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."get_or_create_domain_id"("email" "text") RETURNS bigint
    LANGUAGE "plpgsql"
    AS $$
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
$$;

ALTER FUNCTION "public"."get_or_create_domain_id"("email" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."invitee"("public"."event_x") RETURNS SETOF "public"."invitee"
    LANGUAGE "sql" STABLE
    AS $_$
    SELECT
        *
    FROM
        invitee
    WHERE
        event_id = $1.id
$_$;

ALTER FUNCTION "public"."invitee"("public"."event_x") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."redeem_invitation"("_user_id" bigint, "_invitation" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
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

$$;

ALTER FUNCTION "public"."redeem_invitation"("_user_id" bigint, "_invitation" "text") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."upsert_contacts"("_contacts" "public"."contact_upsert"[]) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
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
$$;

ALTER FUNCTION "public"."upsert_contacts"("_contacts" "public"."contact_upsert"[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."upsert_invitees"("_event_ids" bigint[], "_invitees" "public"."invitee_upsert"[]) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
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
$$;

ALTER FUNCTION "public"."upsert_invitees"("_event_ids" bigint[], "_invitees" "public"."invitee_upsert"[]) OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."week_from_date"("d" "date") RETURNS "daterange"
    LANGUAGE "sql" STABLE
    AS $$
    SELECT
        CASE WHEN d IS NULL THEN
            NULL
        ELSE
            daterange(date_bin ('7 days', d, '2023-1-1'::date)::date, date_bin ('7 days', d, '2023-1-1'::date)::date + 7, '[)'::text)
        END
$$;

ALTER FUNCTION "public"."week_from_date"("d" "date") OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."work_day_end"() RETURNS time without time zone
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    AS $$
    SELECT
        '17:00'::time
$$;

ALTER FUNCTION "public"."work_day_end"() OWNER TO "postgres";

CREATE OR REPLACE FUNCTION "public"."work_day_start"() RETURNS time without time zone
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    AS $$
    SELECT
        '09:00'::time
$$;

ALTER FUNCTION "public"."work_day_start"() OWNER TO "postgres";

ALTER TABLE "public"."account" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."account_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE "public"."activity" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."activity_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE "public"."budget" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."budget_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE "public"."calendar" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."calendar_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE "public"."contact" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."contact_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."domain" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "domain" "text" NOT NULL,
    "organization_id" bigint,
    CONSTRAINT "domain_domain_check" CHECK ("public"."is_lower"("domain"))
);

ALTER TABLE "public"."domain" OWNER TO "postgres";

ALTER TABLE "public"."domain" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."domain_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE OR REPLACE FUNCTION "public"."organization"("public"."account") RETURNS SETOF "public"."organization"
    LANGUAGE "sql" STABLE ROWS 1
    AS $_$
    SELECT
        organization.*
    FROM
        organization
        JOIN "domain" ON organization.id = domain.organization_id
    WHERE
        domain.id = $1.domain_id
$_$;

CREATE OR REPLACE FUNCTION "public"."organization"("public"."contact") RETURNS SETOF "public"."organization"
    LANGUAGE "sql" STABLE ROWS 1
    AS $_$
    SELECT
        organization.*
    FROM
        organization
        JOIN "domain" ON organization.id = domain.organization_id
    WHERE
        domain.id = $1.domain_id
$_$;

ALTER FUNCTION "public"."organization"("public"."account") OWNER TO "postgres";

ALTER FUNCTION "public"."organization"("public"."contact") OWNER TO "postgres";



ALTER TABLE "public"."event" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."event_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE OR REPLACE VIEW "public"."gap" WITH ("security_invoker"='true') AS
 SELECT "gap"."user_id",
    "gap"."day",
    ("gap"."at" * "tstzrange"((("gap"."day" + "public"."work_day_start"()) AT TIME ZONE "public"."user_timezone"()), (("gap"."day" + "public"."work_day_end"()) AT TIME ZONE "public"."user_timezone"()), '[]'::"text")) AS "at",
    "public"."extract_minutes"(("gap"."at" * "tstzrange"((("gap"."day" + "public"."work_day_start"()) AT TIME ZONE "public"."user_timezone"()), (("gap"."day" + "public"."work_day_end"()) AT TIME ZONE "public"."user_timezone"()), '[]'::"text"))) AS "minutes"
   FROM ( SELECT "e"."user_id",
            "e"."day",
                CASE
                    WHEN ((EXTRACT(isodow FROM "e"."day") <= (5)::numeric) AND ("max"("upper"("e"."at")) OVER "start_window" < "lower"("e"."at"))) THEN "tstzrange"("max"("upper"("e"."at")) OVER "start_window", "lower"("e"."at"), '[)'::"text")
                    ELSE NULL::"tstzrange"
                END AS "at"
           FROM ( SELECT "event_x"."user_id",
                    "event_x"."day",
                    "event_x"."at"
                   FROM "public"."event_x"
                  WHERE (("event_x"."type" = 'meeting'::"public"."event_type") AND ("event_x"."status" <> 'cancelled'::"public"."event_status") AND ("event_x"."response" = 'accepted'::"public"."event_response"))
                UNION
                 SELECT DISTINCT "auth"."uid"() AS "id",
                    "days"."day",
                    "tstzrange"((("days"."day" + '1 day'::interval) AT TIME ZONE "public"."user_timezone"()), (("days"."day" + '1 day'::interval) AT TIME ZONE "public"."user_timezone"()), '[]'::"text") AS "at"
                   FROM ( SELECT ("generate_series"((("min"("lower"("event"."at")))::"date")::timestamp with time zone, (("max"("upper"("event"."at")))::"date")::timestamp with time zone, '1 day'::interval))::"date" AS "day"
                           FROM "public"."event") "days") "e"
          WINDOW "start_window" AS (PARTITION BY "e"."user_id" ORDER BY ("lower"("e"."at")), ("upper"("e"."at")) ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)) "gap"
  WHERE ("gap"."at" IS NOT NULL);

ALTER TABLE "public"."gap" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."gap_daily" WITH ("security_invoker"='true') AS
 SELECT "gap"."user_id",
    "gap"."day",
    "sum"("gap"."minutes") AS "total",
    "sum"("gap"."minutes") FILTER (WHERE ("gap"."minutes" >= 60)) AS "focus"
   FROM "public"."gap"
  GROUP BY "gap"."user_id", "gap"."day";

ALTER TABLE "public"."gap_daily" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."gap_monthly" WITH ("security_invoker"='true') AS
 SELECT "gap"."user_id",
    ("date_trunc"('month'::"text", ("gap"."day")::timestamp with time zone))::"date" AS "month",
    "sum"("gap"."minutes") AS "total",
    "sum"("gap"."minutes") FILTER (WHERE ("gap"."minutes" >= 60)) AS "focus"
   FROM "public"."gap"
  GROUP BY "gap"."user_id", (("date_trunc"('month'::"text", ("gap"."day")::timestamp with time zone))::"date");

ALTER TABLE "public"."gap_monthly" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."insight" WITH ("security_invoker"='true') AS
 SELECT "e"."user_id",
    "e"."day",
    "extensions"."text2ltree"("min"("extensions"."ltree2text"("e"."activity_path"))) AS "activity_path",
    "e"."type",
    "e"."response",
    "nv"."name",
    "nv"."value",
    ("count"(*))::integer AS "count",
    ("sum"("e"."minutes"))::integer AS "minutes"
   FROM ("public"."event_x" "e"
     CROSS JOIN LATERAL ( VALUES ('Total'::"text",NULL::"text"), ('Length'::"text",("e"."rounded_length")::"text"), ('Size'::"text","e"."size"), ('Organizer'::"text",
                CASE
                    WHEN "e"."initiated" THEN 'You'::"text"
                    ELSE "e"."organizer_email"
                END), ('External'::"text",
                CASE
                    WHEN ("e"."internal" = 'internal'::"public"."event_internal") THEN 'Interal'::"text"
                    WHEN ("e"."internal" = 'external'::"public"."event_internal") THEN 'External'::"text"
                    ELSE NULL::"text"
                END), ('Recurring'::"text",
                CASE
                    WHEN "e"."recurring" THEN 'Recurring'::"text"
                    ELSE 'Ad hoc'::"text"
                END), ('Notice'::"text",
                CASE
                    WHEN ("e"."notice" < 12) THEN '< 12 hours'::"text"
                    WHEN ("e"."notice" < 24) THEN '< 24 hours'::"text"
                    WHEN ("e"."notice" < (24 * 7)) THEN '< week'::"text"
                    ELSE '> week'::"text"
                END)) "nv"("name", "value"))
  WHERE ("e"."status" <> 'cancelled'::"public"."event_status")
  GROUP BY "e"."user_id", "e"."day", "e"."activity_path", "e"."type", "e"."response", "nv"."name", "nv"."value";

ALTER TABLE "public"."insight" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."insight_weekly" WITH ("security_invoker"='true') AS
 SELECT "c"."user_id",
    "c"."path",
    "public"."week_from_date"("i"."day") AS "week",
    "i"."type",
    "i"."name",
    "i"."value",
    COALESCE("sum"("i"."count") FILTER (WHERE ("i"."response" = 'accepted'::"public"."event_response")), (0)::bigint) AS "count",
    COALESCE("sum"("i"."minutes") FILTER (WHERE ("i"."response" = 'accepted'::"public"."event_response")), (0)::bigint) AS "minutes",
    COALESCE("sum"("i"."count") FILTER (WHERE ("i"."response" IS NULL)), (0)::bigint) AS "pending_count",
    COALESCE("sum"("i"."minutes") FILTER (WHERE ("i"."response" IS NULL)), (0)::bigint) AS "pending_minutes"
   FROM ("public"."activity" "c"
     LEFT JOIN "public"."insight" "i" ON (("c"."path" OPERATOR("extensions".=) "i"."activity_path")))
  GROUP BY "c"."user_id", "c"."path", ("public"."week_from_date"("i"."day")), "i"."type", "i"."name", "i"."value";

ALTER TABLE "public"."insight_weekly" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."invitation" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "code" "text" NOT NULL,
    "remaining" numeric DEFAULT '1'::numeric NOT NULL
);

ALTER TABLE "public"."invitation" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."waitlist" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "email" "text" NOT NULL,
    "invitation" "text",
    "activated_at" timestamp with time zone
);

ALTER TABLE "public"."waitlist" OWNER TO "postgres";

CREATE OR REPLACE VIEW "public"."invitation_admin" WITH ("security_invoker"='false') AS
 SELECT "min"("i"."id") AS "id",
    "min"("i"."created_at") AS "created_at",
    "min"("i"."code") AS "code",
    "min"("i"."remaining") AS "remaining",
    "count"("w"."invitation") AS "uses"
   FROM ("public"."invitation" "i"
     LEFT JOIN "public"."waitlist" "w" ON (("w"."invitation" = "i"."code")))
  GROUP BY "i"."id";

ALTER TABLE "public"."invitation_admin" OWNER TO "postgres";

ALTER TABLE "public"."invitation" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."invitation_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."note" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "activity_id" bigint,
    "body" "text" NOT NULL
);

ALTER TABLE "public"."note" OWNER TO "postgres";

ALTER TABLE "public"."note" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."note_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE "public"."organization" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."organization_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE TABLE IF NOT EXISTS "public"."raw_event" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "calendar_id" bigint,
    "event" "jsonb" NOT NULL,
    "provider_id" "text" NOT NULL
);

ALTER TABLE "public"."raw_event" OWNER TO "postgres";

ALTER TABLE "public"."raw_event" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."raw_event_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE "public"."rule" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."rule_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE OR REPLACE VIEW "public"."sync_admin" AS
SELECT
    NULL::"text" AS "email",
    NULL::bigint AS "account_id",
    NULL::"jsonb" AS "provider",
    NULL::"text" AS "calendar_provider_id",
    NULL::timestamp with time zone AS "first_synced_at",
    NULL::timestamp with time zone AS "full_sync_at",
    NULL::timestamp with time zone AS "synced_at",
    NULL::"text" AS "error",
    NULL::numeric AS "sync_seconds",
    NULL::bigint AS "event_count";

ALTER TABLE "public"."sync_admin" OWNER TO "postgres";

CREATE TABLE IF NOT EXISTS "public"."time" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "activity_id" bigint,
    "at" "tstzrange" NOT NULL,
    "event_id" bigint,
    "planned" interval NOT NULL,
    "remaining" interval DEFAULT '00:00:00'::interval NOT NULL,
    "series_id" bigint,
    CONSTRAINT "time_at_check" CHECK ("public"."is_finite"("at")),
    CONSTRAINT "time_check" CHECK ((("remaining" >= '00:00:00'::interval) AND ("remaining" <= "planned"))),
    CONSTRAINT "time_planned_check" CHECK (("planned" >= '00:00:00'::interval))
);

ALTER TABLE "public"."time" OWNER TO "postgres";

ALTER TABLE "public"."time" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."time_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

CREATE OR REPLACE VIEW "public"."waitlist_admin" AS
SELECT
    NULL::bigint AS "id",
    NULL::timestamp with time zone AS "created_at",
    NULL::"text" AS "email",
    NULL::"text" AS "status",
    NULL::"text"[] AS "sync_accounts",
    NULL::"text"[] AS "sync_error",
    NULL::"jsonb" AS "provider",
    NULL::"text" AS "invitation",
    NULL::bigint AS "event_count";

ALTER TABLE "public"."waitlist_admin" OWNER TO "postgres";

ALTER TABLE "public"."waitlist" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."waitlist_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY "public"."account"
    ADD CONSTRAINT "account_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."account"
    ADD CONSTRAINT "account_user_id_email_key" UNIQUE ("user_id", "email");

ALTER TABLE ONLY "public"."activity"
    ADD CONSTRAINT "activity_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."budget"
    ADD CONSTRAINT "budget_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."budget"
    ADD CONSTRAINT "budget_user_activity_week_unique" UNIQUE NULLS NOT DISTINCT ("user_id", "activity_id", "week");

ALTER TABLE ONLY "public"."calendar"
    ADD CONSTRAINT "calendar_account_provider_id_unique" UNIQUE ("account_id", "provider_id");

ALTER TABLE ONLY "public"."calendar"
    ADD CONSTRAINT "calendar_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."raw_event"
    ADD CONSTRAINT "calendar_provider_id_unique" UNIQUE ("calendar_id", "provider_id");

ALTER TABLE ONLY "public"."contact"
    ADD CONSTRAINT "contact_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."contact"
    ADD CONSTRAINT "contact_user_email_unique" UNIQUE NULLS NOT DISTINCT ("user_id", "email");

ALTER TABLE ONLY "public"."domain"
    ADD CONSTRAINT "domain_domain_key" UNIQUE ("domain");

ALTER TABLE ONLY "public"."domain"
    ADD CONSTRAINT "domain_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."event"
    ADD CONSTRAINT "event_calendar_provider_id_unique" UNIQUE NULLS NOT DISTINCT ("calendar_id", "provider_id");

ALTER TABLE ONLY "public"."event"
    ADD CONSTRAINT "event_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."invitation"
    ADD CONSTRAINT "invitation_code_key" UNIQUE ("code");

ALTER TABLE ONLY "public"."invitation"
    ADD CONSTRAINT "invitation_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."invitee"
    ADD CONSTRAINT "invitee_event_email_unique" UNIQUE ("event_id", "email");

ALTER TABLE ONLY "public"."note"
    ADD CONSTRAINT "note_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."organization"
    ADD CONSTRAINT "organization_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."raw_event"
    ADD CONSTRAINT "raw_event_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."rule"
    ADD CONSTRAINT "rule_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."rule"
    ADD CONSTRAINT "rule_unique" UNIQUE NULLS NOT DISTINCT ("user_id", "series", "name", "invitees", "invitee_domain", "account_id", "calendar_id", "internal", "type");

ALTER TABLE ONLY "public"."time"
    ADD CONSTRAINT "time_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."time"
    ADD CONSTRAINT "time_user_id_at_excl" EXCLUDE USING "gist" ("user_id" WITH =, "at" WITH &&);

ALTER TABLE ONLY "public"."activity"
    ADD CONSTRAINT "user_path_unique" UNIQUE ("user_id", "path");

ALTER TABLE ONLY "public"."waitlist"
    ADD CONSTRAINT "waitlist_pkey" PRIMARY KEY ("id");

CREATE INDEX "account_user_id_idx" ON "public"."account" USING "btree" ("user_id");

CREATE INDEX "activity_path_idx" ON "public"."activity" USING "gist" ("user_id", "path");

CREATE INDEX "calendar_account_id_idx" ON "public"."calendar" USING "btree" ("account_id");

CREATE INDEX "event_at_idx" ON "public"."event" USING "spgist" ("at");

CREATE INDEX "invitee_event_id_idx" ON "public"."invitee" USING "btree" ("event_id");

CREATE INDEX "rule_user_id_key" ON "public"."rule" USING "btree" ("user_id");

CREATE INDEX "time_at_idx" ON "public"."time" USING "spgist" ("at");

CREATE OR REPLACE VIEW "public"."sync_admin" WITH ("security_invoker"='false') AS
 SELECT "min"("a"."email") AS "email",
    "min"("a"."id") AS "account_id",
    (("array_agg"("a"."credentials"))[0] -> 'provider'::"text") AS "provider",
    "c"."provider_id" AS "calendar_provider_id",
    "c"."created_at" AS "first_synced_at",
    "c"."full_sync_at",
    "c"."synced_at",
    "c"."sync_error" AS "error",
        CASE
            WHEN (("c"."full_sync_at" IS NULL) OR ("c"."sync_error" IS NOT NULL)) THEN NULL::numeric
            ELSE "round"(EXTRACT(epoch FROM (COALESCE("c"."full_sync_at", "now"()) - "c"."full_sync_started_at")))
        END AS "sync_seconds",
    "count"("e"."id") AS "event_count"
   FROM (("public"."account" "a"
     LEFT JOIN "public"."calendar" "c" ON (("c"."account_id" = "a"."id")))
     LEFT JOIN "public"."event" "e" ON (("e"."calendar_id" = "c"."id")))
  GROUP BY "c"."id";

CREATE OR REPLACE VIEW "public"."waitlist_admin" WITH ("security_invoker"='false') AS
 SELECT "min"("w"."id") AS "id",
    "min"("w"."created_at") AS "created_at",
    "min"("w"."email") AS "email",
        CASE
            WHEN ("min"("c"."sync_error") IS NOT NULL) THEN 'sync_error'::"text"
            WHEN ("min"("w"."activated_at") IS NOT NULL) THEN 'active'::"text"
            WHEN ("count"(*) FILTER (WHERE (("a"."credentials" -> 'refresh_token'::"text") IS NOT NULL)) > 0) THEN 'synced'::"text"
            ELSE 'waitlisted'::"text"
        END AS "status",
    "array_agg"(DISTINCT "a"."email") FILTER (WHERE ("a"."email" IS NOT NULL)) AS "sync_accounts",
    "array_agg"("c"."sync_error") FILTER (WHERE ("c"."sync_error" IS NOT NULL)) AS "sync_error",
    (("array_agg"("a"."credentials"))[0] -> 'provider'::"text") AS "provider",
    "w"."invitation",
    "count"("e"."id") AS "event_count"
   FROM ((("public"."waitlist" "w"
     LEFT JOIN "public"."account" "a" ON ((("w"."email" = "a"."email") AND ("a"."credentials" IS NOT NULL))))
     LEFT JOIN "public"."calendar" "c" ON (("c"."account_id" = "a"."id")))
     LEFT JOIN "public"."event" "e" ON (("e"."calendar_id" = "c"."id")))
  GROUP BY "w"."id";

CREATE OR REPLACE TRIGGER "on_account_created" AFTER INSERT ON "public"."account" FOR EACH ROW EXECUTE FUNCTION "public"."link_account_to_domain"();

CREATE OR REPLACE TRIGGER "on_contact_created" BEFORE INSERT ON "public"."contact" FOR EACH ROW EXECUTE FUNCTION "public"."link_contact_to_domain"();

ALTER TABLE ONLY "public"."account"
    ADD CONSTRAINT "account_domain_id_fkey" FOREIGN KEY ("domain_id") REFERENCES "public"."domain"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."account"
    ADD CONSTRAINT "account_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."activity"
    ADD CONSTRAINT "activity_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."budget"
    ADD CONSTRAINT "budget_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."activity"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."budget"
    ADD CONSTRAINT "budget_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."calendar"
    ADD CONSTRAINT "calendar_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."account"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."contact"
    ADD CONSTRAINT "contact_domain_id_fkey" FOREIGN KEY ("domain_id") REFERENCES "public"."domain"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."contact"
    ADD CONSTRAINT "contact_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."domain"
    ADD CONSTRAINT "domain_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organization"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."event"
    ADD CONSTRAINT "event_calendar_id_fkey" FOREIGN KEY ("calendar_id") REFERENCES "public"."calendar"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."invitee"
    ADD CONSTRAINT "invitee_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."event"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."note"
    ADD CONSTRAINT "note_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."activity"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."note"
    ADD CONSTRAINT "note_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."raw_event"
    ADD CONSTRAINT "raw_event_calendar_id_fkey" FOREIGN KEY ("calendar_id") REFERENCES "public"."calendar"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."rule"
    ADD CONSTRAINT "rule_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."account"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."rule"
    ADD CONSTRAINT "rule_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."activity"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."rule"
    ADD CONSTRAINT "rule_calendar_id_fkey" FOREIGN KEY ("calendar_id") REFERENCES "public"."calendar"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."rule"
    ADD CONSTRAINT "rule_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."time"
    ADD CONSTRAINT "time_activity_id_fkey" FOREIGN KEY ("activity_id") REFERENCES "public"."activity"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."time"
    ADD CONSTRAINT "time_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."event"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."time"
    ADD CONSTRAINT "time_series_id_fkey" FOREIGN KEY ("series_id") REFERENCES "public"."time"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."time"
    ADD CONSTRAINT "time_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

CREATE POLICY "Everyone can view all domains" ON "public"."domain" FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "Everyone can view all organizations" ON "public"."organization" FOR SELECT TO "authenticated" USING (true);

CREATE POLICY "Users can edit their invitees for their events" ON "public"."invitee" TO "authenticated" USING (("event_id" IN ( SELECT "event"."id"
   FROM "public"."event")));

CREATE POLICY "Users can edit their notes" ON "public"."note" TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can edit their rules" ON "public"."rule" TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can edit their time" ON "public"."time" TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can read their accounts" ON "public"."account" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can read/write their activities" ON "public"."activity" TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can read/write their budgets" ON "public"."budget" TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can view their contact" ON "public"."contact" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "Users can view their own calendars" ON "public"."calendar" FOR SELECT TO "authenticated" USING (("account_id" IN ( SELECT "account"."id"
   FROM "public"."account")));

CREATE POLICY "Users can view their own events" ON "public"."event" FOR SELECT TO "authenticated" USING (("calendar_id" IN ( SELECT "calendar"."id"
   FROM "public"."calendar")));

ALTER TABLE "public"."account" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."budget" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."calendar" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."contact" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."domain" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."event" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "internal_admin can access all invitations" ON "public"."invitation" TO "internal_admin" USING (true);

CREATE POLICY "internal_admin can edit the wailist" ON "public"."waitlist" TO "internal_admin" USING (true);

ALTER TABLE "public"."invitation" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."invitee" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."note" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."organization" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."raw_event" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."rule" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."time" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."waitlist" ENABLE ROW LEVEL SECURITY;

GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

GRANT ALL ON TABLE "public"."account" TO "anon";
GRANT ALL ON TABLE "public"."account" TO "authenticated";
GRANT ALL ON TABLE "public"."account" TO "service_role";

GRANT ALL ON TABLE "public"."calendar" TO "anon";
GRANT ALL ON TABLE "public"."calendar" TO "authenticated";
GRANT ALL ON TABLE "public"."calendar" TO "service_role";

GRANT ALL ON FUNCTION "public"."account"("public"."calendar") TO "anon";
GRANT ALL ON FUNCTION "public"."account"("public"."calendar") TO "authenticated";
GRANT ALL ON FUNCTION "public"."account"("public"."calendar") TO "service_role";

GRANT ALL ON FUNCTION "public"."all_views_secure"() TO "anon";
GRANT ALL ON FUNCTION "public"."all_views_secure"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."all_views_secure"() TO "service_role";

GRANT ALL ON FUNCTION "public"."is_week"("p_week" "daterange") TO "anon";
GRANT ALL ON FUNCTION "public"."is_week"("p_week" "daterange") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_week"("p_week" "daterange") TO "service_role";

GRANT ALL ON TABLE "public"."activity" TO "anon";
GRANT ALL ON TABLE "public"."activity" TO "authenticated";
GRANT ALL ON TABLE "public"."activity" TO "service_role";

GRANT ALL ON TABLE "public"."budget" TO "anon";
GRANT ALL ON TABLE "public"."budget" TO "authenticated";
GRANT ALL ON TABLE "public"."budget" TO "service_role";

GRANT ALL ON FUNCTION "public"."budget"("public"."activity") TO "anon";
GRANT ALL ON FUNCTION "public"."budget"("public"."activity") TO "authenticated";
GRANT ALL ON FUNCTION "public"."budget"("public"."activity") TO "service_role";

GRANT ALL ON FUNCTION "public"."budget_week"("user_id" "uuid", "week" "daterange") TO "anon";
GRANT ALL ON FUNCTION "public"."budget_week"("user_id" "uuid", "week" "daterange") TO "authenticated";
GRANT ALL ON FUNCTION "public"."budget_week"("user_id" "uuid", "week" "daterange") TO "service_role";

GRANT ALL ON FUNCTION "public"."calc_all_day"("at" "tstzrange") TO "anon";
GRANT ALL ON FUNCTION "public"."calc_all_day"("at" "tstzrange") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calc_all_day"("at" "tstzrange") TO "service_role";

GRANT ALL ON FUNCTION "public"."calc_event_type"("at" "tstzrange", "availability" "public"."event_availability", "response" "public"."event_response", "has_invitees" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."calc_event_type"("at" "tstzrange", "availability" "public"."event_availability", "response" "public"."event_response", "has_invitees" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calc_event_type"("at" "tstzrange", "availability" "public"."event_availability", "response" "public"."event_response", "has_invitees" boolean) TO "service_role";

GRANT ALL ON FUNCTION "public"."calc_internal"("invitee_count" integer, "user_domain" bigint, "domains" bigint[]) TO "anon";
GRANT ALL ON FUNCTION "public"."calc_internal"("invitee_count" integer, "user_domain" bigint, "domains" bigint[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calc_internal"("invitee_count" integer, "user_domain" bigint, "domains" bigint[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."calc_meeting_size"("invitee_count" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."calc_meeting_size"("invitee_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calc_meeting_size"("invitee_count" integer) TO "service_role";

GRANT ALL ON FUNCTION "public"."calc_minutes"("at" "tstzrange") TO "anon";
GRANT ALL ON FUNCTION "public"."calc_minutes"("at" "tstzrange") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calc_minutes"("at" "tstzrange") TO "service_role";

GRANT ALL ON FUNCTION "public"."calc_notice"("created_at" timestamp with time zone, "at" "tstzrange") TO "anon";
GRANT ALL ON FUNCTION "public"."calc_notice"("created_at" timestamp with time zone, "at" "tstzrange") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calc_notice"("created_at" timestamp with time zone, "at" "tstzrange") TO "service_role";

GRANT ALL ON FUNCTION "public"."calc_rounded_length"("at" "tstzrange") TO "anon";
GRANT ALL ON FUNCTION "public"."calc_rounded_length"("at" "tstzrange") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calc_rounded_length"("at" "tstzrange") TO "service_role";

GRANT ALL ON FUNCTION "public"."calc_speedy"("at" "tstzrange") TO "anon";
GRANT ALL ON FUNCTION "public"."calc_speedy"("at" "tstzrange") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calc_speedy"("at" "tstzrange") TO "service_role";

GRANT ALL ON FUNCTION "public"."is_lower"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."is_lower"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_lower"("text") TO "service_role";

GRANT ALL ON FUNCTION "public"."user_timezone"() TO "anon";
GRANT ALL ON FUNCTION "public"."user_timezone"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."user_timezone"() TO "service_role";

GRANT ALL ON TABLE "public"."contact" TO "anon";
GRANT ALL ON TABLE "public"."contact" TO "authenticated";
GRANT ALL ON TABLE "public"."contact" TO "service_role";

GRANT ALL ON TABLE "public"."event" TO "anon";
GRANT ALL ON TABLE "public"."event" TO "authenticated";
GRANT ALL ON TABLE "public"."event" TO "service_role";

GRANT ALL ON TABLE "public"."invitee" TO "anon";
GRANT ALL ON TABLE "public"."invitee" TO "authenticated";
GRANT ALL ON TABLE "public"."invitee" TO "service_role";

GRANT ALL ON TABLE "public"."rule" TO "anon";
GRANT ALL ON TABLE "public"."rule" TO "authenticated";
GRANT ALL ON TABLE "public"."rule" TO "service_role";

GRANT ALL ON TABLE "public"."event_x" TO "anon";
GRANT ALL ON TABLE "public"."event_x" TO "authenticated";
GRANT ALL ON TABLE "public"."event_x" TO "service_role";

GRANT ALL ON FUNCTION "public"."calendar"("public"."event_x") TO "anon";
GRANT ALL ON FUNCTION "public"."calendar"("public"."event_x") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calendar"("public"."event_x") TO "service_role";

GRANT ALL ON FUNCTION "public"."calendars"("public"."account") TO "anon";
GRANT ALL ON FUNCTION "public"."calendars"("public"."account") TO "authenticated";
GRANT ALL ON FUNCTION "public"."calendars"("public"."account") TO "service_role";

GRANT ALL ON FUNCTION "public"."cancel_events"("_events" "public"."event_ids"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."cancel_events"("_events" "public"."event_ids"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_events"("_events" "public"."event_ids"[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."contact"("public"."invitee") TO "anon";
GRANT ALL ON FUNCTION "public"."contact"("public"."invitee") TO "authenticated";
GRANT ALL ON FUNCTION "public"."contact"("public"."invitee") TO "service_role";

GRANT ALL ON FUNCTION "public"."extract_minutes"("r" "tstzrange") TO "anon";
GRANT ALL ON FUNCTION "public"."extract_minutes"("r" "tstzrange") TO "authenticated";
GRANT ALL ON FUNCTION "public"."extract_minutes"("r" "tstzrange") TO "service_role";

GRANT ALL ON FUNCTION "public"."get_or_create_domain_id"("email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_or_create_domain_id"("email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_or_create_domain_id"("email" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."invitee"("public"."event_x") TO "anon";
GRANT ALL ON FUNCTION "public"."invitee"("public"."event_x") TO "authenticated";
GRANT ALL ON FUNCTION "public"."invitee"("public"."event_x") TO "service_role";

GRANT ALL ON FUNCTION "public"."is_finite"("test" "tstzrange") TO "anon";
GRANT ALL ON FUNCTION "public"."is_finite"("test" "tstzrange") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_finite"("test" "tstzrange") TO "service_role";

GRANT ALL ON FUNCTION "public"."link_account_to_domain"() TO "anon";
GRANT ALL ON FUNCTION "public"."link_account_to_domain"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."link_account_to_domain"() TO "service_role";

GRANT ALL ON FUNCTION "public"."link_contact_to_domain"() TO "anon";
GRANT ALL ON FUNCTION "public"."link_contact_to_domain"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."link_contact_to_domain"() TO "service_role";

GRANT ALL ON TABLE "public"."organization" TO "anon";
GRANT ALL ON TABLE "public"."organization" TO "authenticated";
GRANT ALL ON TABLE "public"."organization" TO "service_role";

GRANT ALL ON FUNCTION "public"."organization"("public"."account") TO "anon";
GRANT ALL ON FUNCTION "public"."organization"("public"."account") TO "authenticated";
GRANT ALL ON FUNCTION "public"."organization"("public"."account") TO "service_role";

GRANT ALL ON FUNCTION "public"."organization"("public"."contact") TO "anon";
GRANT ALL ON FUNCTION "public"."organization"("public"."contact") TO "authenticated";
GRANT ALL ON FUNCTION "public"."organization"("public"."contact") TO "service_role";

GRANT ALL ON FUNCTION "public"."redeem_invitation"("_user_id" bigint, "_invitation" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."redeem_invitation"("_user_id" bigint, "_invitation" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."redeem_invitation"("_user_id" bigint, "_invitation" "text") TO "service_role";

GRANT ALL ON FUNCTION "public"."upsert_contacts"("_contacts" "public"."contact_upsert"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_contacts"("_contacts" "public"."contact_upsert"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_contacts"("_contacts" "public"."contact_upsert"[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."upsert_invitees"("_event_ids" bigint[], "_invitees" "public"."invitee_upsert"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_invitees"("_event_ids" bigint[], "_invitees" "public"."invitee_upsert"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_invitees"("_event_ids" bigint[], "_invitees" "public"."invitee_upsert"[]) TO "service_role";

GRANT ALL ON FUNCTION "public"."week_from_date"("d" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."week_from_date"("d" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."week_from_date"("d" "date") TO "service_role";

GRANT ALL ON FUNCTION "public"."work_day_end"() TO "anon";
GRANT ALL ON FUNCTION "public"."work_day_end"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."work_day_end"() TO "service_role";

GRANT ALL ON FUNCTION "public"."work_day_start"() TO "anon";
GRANT ALL ON FUNCTION "public"."work_day_start"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."work_day_start"() TO "service_role";

GRANT ALL ON SEQUENCE "public"."account_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."account_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."account_id_seq" TO "service_role";

GRANT ALL ON SEQUENCE "public"."activity_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."activity_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."activity_id_seq" TO "service_role";

GRANT ALL ON SEQUENCE "public"."budget_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."budget_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."budget_id_seq" TO "service_role";

GRANT ALL ON SEQUENCE "public"."calendar_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."calendar_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."calendar_id_seq" TO "service_role";

GRANT ALL ON SEQUENCE "public"."contact_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."contact_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."contact_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."domain" TO "anon";
GRANT ALL ON TABLE "public"."domain" TO "authenticated";
GRANT ALL ON TABLE "public"."domain" TO "service_role";

GRANT ALL ON SEQUENCE "public"."domain_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."domain_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."domain_id_seq" TO "service_role";

GRANT ALL ON SEQUENCE "public"."event_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."event_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."event_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."gap" TO "anon";
GRANT ALL ON TABLE "public"."gap" TO "authenticated";
GRANT ALL ON TABLE "public"."gap" TO "service_role";

GRANT ALL ON TABLE "public"."gap_daily" TO "anon";
GRANT ALL ON TABLE "public"."gap_daily" TO "authenticated";
GRANT ALL ON TABLE "public"."gap_daily" TO "service_role";

GRANT ALL ON TABLE "public"."gap_monthly" TO "anon";
GRANT ALL ON TABLE "public"."gap_monthly" TO "authenticated";
GRANT ALL ON TABLE "public"."gap_monthly" TO "service_role";

GRANT ALL ON TABLE "public"."insight" TO "anon";
GRANT ALL ON TABLE "public"."insight" TO "authenticated";
GRANT ALL ON TABLE "public"."insight" TO "service_role";

GRANT ALL ON TABLE "public"."insight_weekly" TO "anon";
GRANT ALL ON TABLE "public"."insight_weekly" TO "authenticated";
GRANT ALL ON TABLE "public"."insight_weekly" TO "service_role";

GRANT ALL ON TABLE "public"."invitation" TO "anon";
GRANT ALL ON TABLE "public"."invitation" TO "authenticated";
GRANT ALL ON TABLE "public"."invitation" TO "service_role";

GRANT ALL ON TABLE "public"."waitlist" TO "anon";
GRANT ALL ON TABLE "public"."waitlist" TO "authenticated";
GRANT ALL ON TABLE "public"."waitlist" TO "service_role";

GRANT ALL ON TABLE "public"."invitation_admin" TO "anon";
GRANT ALL ON TABLE "public"."invitation_admin" TO "authenticated";
GRANT ALL ON TABLE "public"."invitation_admin" TO "service_role";

GRANT ALL ON SEQUENCE "public"."invitation_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."invitation_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."invitation_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."note" TO "anon";
GRANT ALL ON TABLE "public"."note" TO "authenticated";
GRANT ALL ON TABLE "public"."note" TO "service_role";

GRANT ALL ON SEQUENCE "public"."note_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."note_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."note_id_seq" TO "service_role";

GRANT ALL ON SEQUENCE "public"."organization_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."organization_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."organization_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."raw_event" TO "anon";
GRANT ALL ON TABLE "public"."raw_event" TO "authenticated";
GRANT ALL ON TABLE "public"."raw_event" TO "service_role";

GRANT ALL ON SEQUENCE "public"."raw_event_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."raw_event_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."raw_event_id_seq" TO "service_role";

GRANT ALL ON SEQUENCE "public"."rule_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."rule_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."rule_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."sync_admin" TO "anon";
GRANT ALL ON TABLE "public"."sync_admin" TO "authenticated";
GRANT ALL ON TABLE "public"."sync_admin" TO "service_role";

GRANT ALL ON TABLE "public"."time" TO "anon";
GRANT ALL ON TABLE "public"."time" TO "authenticated";
GRANT ALL ON TABLE "public"."time" TO "service_role";

GRANT ALL ON SEQUENCE "public"."time_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."time_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."time_id_seq" TO "service_role";

GRANT ALL ON TABLE "public"."waitlist_admin" TO "anon";
GRANT ALL ON TABLE "public"."waitlist_admin" TO "authenticated";
GRANT ALL ON TABLE "public"."waitlist_admin" TO "service_role";

GRANT ALL ON SEQUENCE "public"."waitlist_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."waitlist_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."waitlist_id_seq" TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";

RESET ALL;
