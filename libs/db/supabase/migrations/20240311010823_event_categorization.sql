CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "extensions";

DROP TRIGGER IF EXISTS "on_account_created" ON "public"."account";

DROP TRIGGER IF EXISTS "on_contact_created" ON "public"."contact";

DROP POLICY "Users can edit their rules" ON "public"."rule";

ALTER TABLE "public"."account"
    DROP CONSTRAINT "account_domain_id_fkey";

ALTER TABLE "public"."contact"
    DROP CONSTRAINT "contact_domain_id_fkey";

ALTER TABLE "public"."domain"
    DROP CONSTRAINT "domain_domain_check";

ALTER TABLE "public"."domain"
    DROP CONSTRAINT "domain_domain_key";

ALTER TABLE "public"."rule"
    DROP CONSTRAINT "rule_account_id_fkey";

ALTER TABLE "public"."rule"
    DROP CONSTRAINT "rule_activity_id_fkey";

ALTER TABLE "public"."rule"
    DROP CONSTRAINT "rule_calendar_id_fkey";

ALTER TABLE "public"."rule"
    DROP CONSTRAINT "rule_unique";

ALTER TABLE "public"."rule"
    DROP CONSTRAINT "rule_user_id_fkey";

DROP FUNCTION IF EXISTS "public"."get_or_create_domain_id" (email text);

DROP FUNCTION IF EXISTS "public"."link_account_to_domain" ();

DROP FUNCTION IF EXISTS "public"."link_contact_to_domain" ();

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."insight_weekly";

DROP VIEW IF EXISTS "public"."sync_admin";

DROP VIEW IF EXISTS "public"."waitlist_admin";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."insight";

DROP FUNCTION IF EXISTS public.calendar (event_x);

DROP FUNCTION IF EXISTS public.invitee (event_x);

DROP VIEW IF EXISTS "public"."event_x";

ALTER TABLE "public"."rule"
    DROP CONSTRAINT "rule_pkey";

DROP INDEX IF EXISTS "public"."domain_domain_key";

DROP INDEX IF EXISTS "public"."rule_pkey";

DROP INDEX IF EXISTS "public"."rule_unique";

DROP INDEX IF EXISTS "public"."rule_user_id_key";

DROP TABLE "public"."rule";

CREATE TABLE "public"."series" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "series" text NOT NULL,
    "invitees" text[],
    "embedding" vector (384),
    "activity_id" bigint
);

ALTER TABLE "public"."series" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."account"
    DROP COLUMN "domain_id";

ALTER TABLE "public"."contact"
    DROP COLUMN "domain_id";

ALTER TABLE "public"."contact"
    DROP COLUMN "is_self";

ALTER TABLE "public"."domain"
    DROP COLUMN "domain";

ALTER TABLE "public"."domain"
    ADD COLUMN "name" text NOT NULL;

CREATE UNIQUE INDEX domain_name_key ON public.domain USING btree (name);

CREATE INDEX name ON public.domain USING btree (name);

CREATE UNIQUE INDEX series_pkey ON public.series USING btree (id);

CREATE UNIQUE INDEX series_unique ON public.series USING btree (user_id, series);

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_pkey" PRIMARY KEY USING INDEX "series_pkey";

ALTER TABLE "public"."account"
    ADD CONSTRAINT "account_email_check" CHECK (is_lower (email)) NOT valid;

ALTER TABLE "public"."account" validate CONSTRAINT "account_email_check";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_name_check" CHECK (is_lower (name)) NOT valid;

ALTER TABLE "public"."domain" validate CONSTRAINT "domain_name_check";

ALTER TABLE "public"."domain"
    ADD CONSTRAINT "domain_name_key" UNIQUE USING INDEX "domain_name_key";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."series" validate CONSTRAINT "series_activity_id_fkey";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_unique" UNIQUE USING INDEX "series_unique";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."series" validate CONSTRAINT "series_user_id_fkey";

SET check_function_bodies = OFF;

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

CREATE OR REPLACE VIEW "public"."event_x" AS
WITH event_x1 AS (
    SELECT
        e_1.user_id,
        min(e_1.id) AS id,
        e_1.name,
        CASE WHEN calc_all_day (e_1.at) THEN
            tstzrange(timezone(user_timezone (), timezone('UTC'::text, lower(e_1.at))), timezone(user_timezone (), timezone('UTC'::text, upper(e_1.at))), '[)'::text)
        ELSE
            e_1.at
        END AS at,
        min(c.account_id) AS account_id,
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
        min(e_1.response) AS response,
        calc_minutes (e_1.at) AS minutes,
        (count(DISTINCT i.email) FILTER (WHERE (i.response = 'accepted'::event_response)))::integer AS attendee_count,
    (count(DISTINCT i.email))::integer AS invitee_count,
    CASE WHEN (EXTRACT(epoch FROM (upper(e_1.at) - lower(e_1.at))) >= (((60 * 60) * 23))::numeric) THEN
        (timezone(user_timezone (), timezone('UTC'::text, lower(e_1.at))))::date
    ELSE
        ((lower(e_1.at) AT TIME ZONE user_timezone ()))::date
    END AS day,
    (array_agg(a.email) && array_agg(e_1.organizer_email)) AS initiated,
    calc_all_day (e_1.at) AS all_day,
    calc_event_type (e_1.at, min(e_1.availability), COALESCE(min(e_1.response), 'tentative'::event_response), (((count(DISTINCT i.email))::integer > 1)
    OR bool_or(e_1.invitees_hidden))) AS type,
    ((min(d.organization_id) IS NOT NULL)
    AND (count(i.email) FILTER (WHERE (get_domain (i.email) <> get_domain (a.email))) > 0)) AS external,
    array_remove(array_agg(DISTINCT i.email ORDER BY i.email), NULL::text) AS invitees,
    array_remove(array_agg(DISTINCT split_part(i.email, '@'::text, 2)
        ORDER BY (split_part(i.email, '@'::text, 2))), NULL::text) AS invitee_domains,
    bool_or(e_1.invitees_hidden) AS invitees_hidden,
    (min(e_1.series) IS NOT NULL) AS recurring,
    calc_notice (min(e_1.created_at), e_1.at) AS notice,
    calc_speedy (e_1.at) AS speedy,
    calc_rounded_length (e_1.at) AS rounded_length,
    calc_meeting_size ((count(DISTINCT i.email))::integer) AS size,
    (array_agg(s_1.embedding))[1] AS embedding
FROM (((((event e_1
                LEFT JOIN invitee i ON (e_1.id = i.event_id))
            LEFT JOIN calendar c ON (e_1.calendar_id = c.id))
        LEFT JOIN account a ON (c.account_id = a.id))
        LEFT JOIN DOMAIN d ON ((d.name = get_domain (a.email))))
        LEFT JOIN series s_1 ON (((s_1.user_id = e_1.user_id)
                    AND (s_1.series = e_1.series))))
    WHERE ((e_1.calendar_id IS NULL)
        OR (c.enabled = TRUE))
GROUP BY
    e_1.user_id,
    e_1.name,
    e_1.at
)
SELECT
    e.user_id,
    e.id,
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
    e.minutes,
    e.attendee_count,
    e.invitee_count,
    e.day,
    e.initiated,
    e.all_day,
    e.type,
    e.external,
    e.invitees,
    e.invitee_domains,
    e.invitees_hidden,
    e.recurring,
    e.notice,
    e.speedy,
    e.rounded_length,
    e.size,
    e.embedding,
    act.id AS activity_id,
    act.path AS activity_path
FROM ((event_x1 e
    LEFT JOIN LATERAL (
        SELECT
            series.activity_id
        FROM
            series
        WHERE ((series.user_id = e.user_id)
            AND (series.activity_id IS NOT NULL))
    ORDER BY
        (series.series = e.series) DESC,
        (series.invitees = e.invitees) DESC,
        (series.embedding <-> e.embedding) DESC
    LIMIT 1) s ON (TRUE))
    LEFT JOIN activity act ON (((e.user_id = act.user_id)
                AND (s.activity_id = act.id))));

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

CREATE POLICY "Users can read all embeddings" ON "public"."event" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "Users can edit their own series" ON "public"."series" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE TRIGGER on_invitee_created
    AFTER INSERT ON public.invitee
    FOR EACH ROW
    EXECUTE FUNCTION insert_email_domain ();

CREATE TRIGGER on_account_created
    AFTER INSERT ON public.account
    FOR EACH ROW
    EXECUTE FUNCTION insert_email_domain ();

CREATE TRIGGER on_contact_created
    AFTER INSERT ON public.contact
    FOR EACH ROW
    EXECUTE FUNCTION insert_email_domain ();

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

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

ALTER VIEW insight_weekly SET (security_invoker = TRUE);

ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

