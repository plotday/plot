CREATE TYPE "public"."budget_type" AS enum (
    'default',
    'balance',
    'exception'
);

DROP POLICY "Users can read/write their budgets" ON "public"."budget";

ALTER TABLE "public"."activity"
    DROP CONSTRAINT "user_path_unique";

ALTER TABLE "public"."budget"
    DROP CONSTRAINT "budget_activity_id_fkey";

ALTER TABLE "public"."budget"
    DROP CONSTRAINT "budget_user_activity_week_unique";

ALTER TABLE "public"."budget"
    DROP CONSTRAINT "budget_user_id_fkey";

ALTER TABLE "public"."budget"
    DROP CONSTRAINT "budget_week_check";

DROP FUNCTION IF EXISTS "public"."budget" (activity);

DROP FUNCTION IF EXISTS "public"."budget_week" (user_id uuid, week daterange);

DROP VIEW IF EXISTS "public"."budget_weekly";

DROP VIEW IF EXISTS "public"."expenditure_weekly";

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."insight_weekly";

DROP VIEW IF EXISTS "public"."time_expenditure";

DROP VIEW IF EXISTS "public"."expenditure";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."insight";

DROP FUNCTION public.invitee (event_x);

DROP FUNCTION public.calendar (event_x);

DROP VIEW IF EXISTS "public"."event_x";

ALTER TABLE "public"."budget"
    DROP CONSTRAINT "budget_pkey";

DROP INDEX IF EXISTS "public"."activity_path_idx";

DROP INDEX IF EXISTS "public"."budget_pkey";

DROP INDEX IF EXISTS "public"."budget_user_activity_week_unique";

DROP INDEX IF EXISTS "public"."user_path_unique";

DROP TABLE "public"."budget";

CREATE TABLE "public"."context" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "name" text NOT NULL,
    "path" ltree NOT NULL
);

ALTER TABLE "public"."context" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "activity_id" bigint,
    "week" daterange NOT NULL,
    "order" text,
    "budget" integer,
    "type" budget_type NOT NULL DEFAULT 'default' ::budget_type
);

ALTER TABLE "public"."priority" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."activity"
    DROP COLUMN "path";

ALTER TABLE "public"."activity"
    ADD COLUMN "context_id" bigint NOT NULL;

ALTER TABLE "public"."time"
    ALTER COLUMN "activity_id" SET NOT NULL;

CREATE INDEX activity_user_id ON public.activity USING btree (user_id);

CREATE INDEX context_path_idx ON public.context USING gist (user_id, path);

CREATE UNIQUE INDEX context_pkey ON public.context USING btree (id);

CREATE UNIQUE INDEX priority_pkey ON public.priority USING btree (id);

CREATE UNIQUE INDEX priority_user_activity_week_unique ON public.priority USING btree (user_id, activity_id, week) NULLS NOT DISTINCT;

CREATE UNIQUE INDEX user_path_unique ON public.context USING btree (user_id, path);

ALTER TABLE "public"."context"
    ADD CONSTRAINT "context_pkey" PRIMARY KEY USING INDEX "context_pkey";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_pkey" PRIMARY KEY USING INDEX "priority_pkey";

ALTER TABLE "public"."activity"
    ADD CONSTRAINT "activity_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity" validate CONSTRAINT "activity_context_id_fkey";

ALTER TABLE "public"."context"
    ADD CONSTRAINT "context_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."context" validate CONSTRAINT "context_user_id_fkey";

ALTER TABLE "public"."context"
    ADD CONSTRAINT "user_path_unique" UNIQUE USING INDEX "user_path_unique";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority" validate CONSTRAINT "priority_activity_id_fkey";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_user_activity_week_unique" UNIQUE USING INDEX "priority_user_activity_week_unique";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority" validate CONSTRAINT "priority_user_id_fkey";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_week_check" CHECK (is_week (week)) NOT valid;

ALTER TABLE "public"."priority" validate CONSTRAINT "priority_week_check";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION priorities_for_week (user_id uuid, week daterange)
    RETURNS TABLE (
        activity_id bigint,
        budget int,
        "budget_type" budget_type,
        "order" text,
        order_type budget_type,
        count int,
        minutes int,
        tentative_count int,
        tentative_minutes int,
        declined_count int,
        declined_minutes int
    )
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        a.id AS activity_id,
        b.budget,
        b.budget_type,
        o.order,
        o.order_type,
        COALESCE(e.count, 0)::int AS count,
        COALESCE(e.minutes, 0)::int AS minutes,
        COALESCE(e.tentative_count, 0)::int AS tentative_count,
        COALESCE(e.tentative_minutes, 0)::int AS tentative_minutes,
        COALESCE(e.declined_count, 0)::int AS declined_count,
        COALESCE(e.declined_minutes, 0)::int AS declined_minutes
    FROM (
        SELECT
            id
        FROM
            activity a
        WHERE
            a.user_id = priorities_for_week.user_id
        UNION ALL
        SELECT
            NULL AS id) AS a
    LEFT JOIN ( SELECT DISTINCT ON (p.activity_id)
            p.activity_id,
            p.budget,
            p.type AS budget_type
        FROM
            priority p
        WHERE
            p.user_id = priorities_for_week.user_id
            AND p.budget IS NOT NULL
            AND p.week <= priorities_for_week.week
            AND (p.type = 'default'
                OR p.week && priorities_for_week.week)
        ORDER BY
            p.activity_id,
            p.week DESC) AS b ON (b.activity_id = a.id
            OR (b.activity_id IS NULL
                AND a.id IS NULL))
        LEFT JOIN ( SELECT DISTINCT ON (p.activity_id)
                p.activity_id,
                p.order,
                p.type AS order_type
            FROM
                priority p
            WHERE
                p.user_id = priorities_for_week.user_id
                AND p.order IS NOT NULL
                AND p.week <= priorities_for_week.week
                AND (p.type = 'default'
                    OR p.week && priorities_for_week.week)
            ORDER BY
                p.activity_id,
                p.week DESC) AS o ON (o.activity_id = a.id
                OR (b.activity_id IS NULL
                    AND a.id IS NULL))
            LEFT JOIN (
                SELECT
                    *
                FROM
                    expenditure_weekly e
                WHERE
                    e.user_id = priorities_for_week.user_id
                    AND e.week && priorities_for_week.week) AS e ON (e.activity_id = a.id
                    OR (b.activity_id IS NULL
                        AND a.id IS NULL));
END;
$$
LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.priority (activity)
    RETURNS SETOF priority
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        *
    FROM
        priority
    WHERE
        activity_id = $1.id;
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
    ctx.path AS context_path
FROM (((event_x1 e
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
                AND (s.activity_id = act.id))))
    LEFT JOIN context ctx ON (((e.user_id = act.user_id)
                AND (ctx.id = act.context_id))));

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

CREATE OR REPLACE FUNCTION public.calendar (event_x)
    RETURNS SETOF calendar ROWS 1
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        calendar.*
    FROM
        calendar
    WHERE
        calendar.id = $1.calendar_id
$function$;

CREATE OR REPLACE VIEW "public"."expenditure" AS
SELECT
    event_x.user_id,
    event_x.day,
    event_x.activity_id,
    COALESCE((count(*) FILTER (WHERE (event_x.response <> 'declined'::event_response)))::integer, 0) AS count,
    COALESCE((sum(event_x.minutes) FILTER (WHERE (event_x.response <> 'declined'::event_response)))::integer, 0) AS minutes,
    COALESCE((count(*) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
        OR (event_x.response IS NULL))))::integer, 0) AS tentative_count,
    COALESCE((sum(event_x.minutes) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
        OR (event_x.response IS NULL))))::integer, 0) AS tentative_minutes,
    COALESCE((count(*) FILTER (WHERE (event_x.response = 'declined'::event_response)))::integer, 0) AS declined_count,
    COALESCE((sum(event_x.minutes) FILTER (WHERE (event_x.response = 'declined'::event_response)))::integer, 0) AS declined_minutes
FROM
    event_x
WHERE (event_x.status <> 'cancelled'::event_status)
GROUP BY
    event_x.user_id,
    event_x.day,
    event_x.activity_id;

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
    text2ltree (min(ltree2text (e.context_path))) AS context_path,
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
    e.context_path,
    e.type,
    e.response,
    nv.name,
    nv.value;

CREATE OR REPLACE VIEW "public"."insight_weekly" AS
SELECT
    act.user_id,
    ctx.path,
    week_from_date (i.day) AS week,
    i.type,
    i.name,
    i.value,
    COALESCE(sum(i.count) FILTER (WHERE (i.response = 'accepted'::event_response)), (0)::bigint) AS count,
    COALESCE(sum(i.minutes) FILTER (WHERE (i.response = 'accepted'::event_response)), (0)::bigint) AS minutes,
    COALESCE(sum(i.count) FILTER (WHERE (i.response IS NULL)), (0)::bigint) AS pending_count,
    COALESCE(sum(i.minutes) FILTER (WHERE (i.response IS NULL)), (0)::bigint) AS pending_minutes
FROM ((activity act
        JOIN context ctx ON (act.context_id = ctx.id))
    LEFT JOIN insight i ON (ctx.path = i.context_path))
GROUP BY
    act.user_id,
    ctx.path,
    (week_from_date (i.day)),
    i.type,
    i.name,
    i.value;

CREATE OR REPLACE VIEW "public"."time_expenditure" AS
SELECT
    "time".user_id,
    ((lower("time".at) AT TIME ZONE user_timezone ()))::date AS day,
    "time".activity_id,
    (count(*))::integer AS count,
    (sum(((EXTRACT(epoch FROM "time".planned) - EXTRACT(epoch FROM "time".remaining)) / (60)::numeric)))::integer AS minutes
FROM
    "time"
GROUP BY
    "time".user_id,
    (((lower("time".at) AT TIME ZONE user_timezone ()))::date),
    "time".activity_id;

CREATE OR REPLACE VIEW "public"."expenditure_weekly" AS
SELECT
    COALESCE(e.user_id, t.user_id) AS user_id,
    week_from_date (COALESCE(e.day, t.day)) AS week,
    COALESCE(e.activity_id, t.activity_id) AS activity_id,
    sum((COALESCE(e.count, 0) + COALESCE(t.count, 0))) AS count,
    sum((COALESCE(e.minutes, 0) + COALESCE(t.minutes, 0))) AS minutes,
    sum(COALESCE(e.tentative_count, 0)) AS tentative_count,
    sum(COALESCE(e.tentative_minutes, 0)) AS tentative_minutes,
    sum(COALESCE(e.declined_count, 0)) AS declined_count,
    sum(COALESCE(e.declined_minutes, 0)) AS declined_minutes
FROM (expenditure e
    FULL JOIN time_expenditure t ON (((e.user_id = t.user_id)
                AND (e.day = t.day)
                AND (e.activity_id = t.activity_id))))
GROUP BY
    COALESCE(e.user_id, t.user_id),
    (week_from_date (COALESCE(e.day, t.day))),
    COALESCE(e.activity_id, t.activity_id);

CREATE POLICY "Users can read/write their contexts" ON "public"."context" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE POLICY "Users can read/write their priorities" ON "public"."priority" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

ALTER VIEW insight_weekly SET (security_invoker = TRUE);

ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW expenditure SET (security_invoker = TRUE);

ALTER VIEW time_expenditure SET (security_invoker = TRUE);

ALTER VIEW expenditure_weekly SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

