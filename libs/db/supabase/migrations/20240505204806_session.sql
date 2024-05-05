DROP POLICY "Users can read/write their activities" ON "public"."activity";

DROP POLICY "Users can edit their time" ON "public"."time";

ALTER TABLE "public"."activity"
    DROP CONSTRAINT "activity_context_id_fkey";

ALTER TABLE "public"."activity"
    DROP CONSTRAINT "activity_user_id_fkey";

ALTER TABLE "public"."note"
    DROP CONSTRAINT "note_activity_id_fkey";

ALTER TABLE "public"."priority"
    DROP CONSTRAINT "priority_activity_id_fkey";

ALTER TABLE "public"."priority"
    DROP CONSTRAINT "priority_user_activity_week_unique";

ALTER TABLE "public"."series"
    DROP CONSTRAINT "series_activity_id_fkey";

ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_activity_id_fkey";

ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_at_check";

ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_check";

ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_event_id_fkey";

ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_planned_check";

ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_series_id_fkey";

ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_user_id_at_excl";

ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_user_id_fkey";

DROP FUNCTION IF EXISTS "public"."priority" (activity);

DROP VIEW IF EXISTS "public"."expenditure_weekly";

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."insight_weekly";

DROP FUNCTION IF EXISTS "public"."priorities_for_week" (user_id uuid, week daterange);

DROP VIEW IF EXISTS "public"."time_expenditure";

DROP VIEW IF EXISTS "public"."expenditure";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."insight";

DROP VIEW IF EXISTS "public"."event_x" CASCADE;

ALTER TABLE "public"."activity"
    DROP CONSTRAINT "activity_pkey";

ALTER TABLE "public"."time"
    DROP CONSTRAINT "time_pkey";

DROP INDEX IF EXISTS "public"."activity_pkey";

DROP INDEX IF EXISTS "public"."activity_user_id";

DROP INDEX IF EXISTS "public"."priority_user_activity_week_unique";

DROP INDEX IF EXISTS "public"."time_at_idx";

DROP INDEX IF EXISTS "public"."time_pkey";

SELECT
    1;

-- drop index if exists "public"."time_user_id_at_excl";
DROP TABLE "public"."activity";

DROP TABLE "public"."time";

CREATE TABLE "public"."session" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "context_id" bigint,
    "event_id" bigint,
    "at" tstzrange NOT NULL,
    "paused" interval NOT NULL DEFAULT '00:00:00' ::interval,
    "pomodoro_start" timestamp with time zone,
    "pomodoro_length" interval
);

ALTER TABLE "public"."session" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."context"
    ADD COLUMN "pomodoro" integer NOT NULL DEFAULT 25;

ALTER TABLE "public"."note"
    DROP COLUMN "activity_id";

ALTER TABLE "public"."note"
    ADD COLUMN "context_id" bigint;

ALTER TABLE "public"."priority"
    DROP COLUMN "activity_id";

ALTER TABLE "public"."priority"
    ADD COLUMN "context_id" bigint;

ALTER TABLE "public"."series"
    DROP COLUMN "activity_id";

ALTER TABLE "public"."series"
    ADD COLUMN "context_id" bigint;

CREATE INDEX context_user_id ON public.context USING btree (user_id);

CREATE UNIQUE INDEX priority_user_context_week_unique ON public.priority USING btree (user_id, context_id, week) NULLS NOT DISTINCT;

CREATE INDEX session_at_idx ON public.session USING spgist (at);

CREATE UNIQUE INDEX session_pkey ON public.session USING btree (id);

SELECT
    1;

-- CREATE INDEX session_user_id_expr_at_excl ON public.session USING gist (user_id, ((EXTRACT(epoch FROM (upper(at) - lower(at))) > (60 * 5)::numeric)), at);
ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_pkey" PRIMARY KEY USING INDEX "session_pkey";

ALTER TABLE "public"."note"
    ADD CONSTRAINT "note_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."note" validate CONSTRAINT "note_context_id_fkey";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority" validate CONSTRAINT "priority_context_id_fkey";

ALTER TABLE "public"."priority"
    ADD CONSTRAINT "priority_user_context_week_unique" UNIQUE USING INDEX "priority_user_context_week_unique";

ALTER TABLE "public"."series"
    ADD CONSTRAINT "series_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."series" validate CONSTRAINT "series_context_id_fkey";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_at_check" CHECK (is_finite (at)) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_at_check";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_check" CHECK (((pomodoro_start >= lower(at)) AND (pomodoro_start <= upper(at)))) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_check";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_context_id_fkey" FOREIGN KEY (context_id) REFERENCES context (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_context_id_fkey";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_event_id_fkey" FOREIGN KEY (event_id) REFERENCES event (id) ON DELETE SET NULL NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_event_id_fkey";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_paused_check" CHECK ((paused >= '00:00:00'::interval)) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_paused_check";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_pomodoro_length_check" CHECK (((pomodoro_length IS NULL) OR (pomodoro_length > '00:00:00'::interval))) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_pomodoro_length_check";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_user_id_expr_at_excl"
    EXCLUDE USING gist (user_id WITH =, ((EXTRACT(epoch FROM (upper(at) - lower(at))) > (60 * 5)::numeric)) WITH =, at WITH &&);

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_user_id_fkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.priority (context)
    RETURNS SETOF priority
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        *
    FROM
        priority
    WHERE
        context_id = $1.id;
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
    LEFT JOIN context ctx ON (((ctx.user_id = e.user_id)
                AND (ctx.id = s.context_id))));

CREATE OR REPLACE VIEW "public"."expenditure" AS
SELECT
    COALESCE(e.user_id, s.user_id) AS user_id,
    COALESCE(e.day, s.day) AS day,
    COALESCE(e.context_id, s.context_id) AS context_id,
    COALESCE((COALESCE(e.count, (0)::bigint) + COALESCE(s.count, (0)::bigint))) AS count,
    COALESCE((COALESCE(e.minutes, (0)::bigint) + COALESCE(s.minutes, 0))) AS minutes,
    COALESCE(e.tentative_count, (0)::bigint) AS tentative_count,
    COALESCE(e.tentative_minutes, (0)::bigint) AS tentative_minutes,
    COALESCE(e.declined_count, (0)::bigint) AS declined_count,
    COALESCE(e.declined_minutes, (0)::bigint) AS declined_minutes
FROM ((
        SELECT
            event_x.user_id,
            event_x.day,
            event_x.context_id,
            COALESCE(count(*) FILTER (WHERE (event_x.response <> 'declined'::event_response)), (0)::bigint) AS count,
            COALESCE(sum(event_x.minutes) FILTER (WHERE (event_x.response <> 'declined'::event_response)), (0)::bigint) AS minutes,
            COALESCE(count(*) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
                OR (event_x.response IS NULL))), (0)::bigint) AS tentative_count,
            COALESCE(sum(event_x.minutes) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
                OR (event_x.response IS NULL))), (0)::bigint) AS tentative_minutes,
            COALESCE(count(*) FILTER (WHERE (event_x.response = 'declined'::event_response)), (0)::bigint) AS declined_count,
            COALESCE(sum(event_x.minutes) FILTER (WHERE (event_x.response = 'declined'::event_response)), (0)::bigint) AS declined_minutes
        FROM
            event_x
        WHERE ((event_x.status <> 'cancelled'::event_status)
            AND (event_x.response <> 'declined'::event_response)
            AND (event_x.all_day = FALSE))
    GROUP BY
        event_x.user_id,
        event_x.day,
        event_x.context_id) e
    FULL JOIN (
        SELECT
            session.user_id,
            ((lower(session.at) AT TIME ZONE user_timezone ()))::date AS day,
            session.context_id,
            count(*) AS count,
            (sum((EXTRACT(epoch FROM ((upper(session.at) - lower(session.at)) - session.paused)) / (60)::numeric)))::integer AS minutes
        FROM
            session
        GROUP BY
            session.user_id,
            (((lower(session.at) AT TIME ZONE user_timezone ()))::date),
            session.context_id) s ON (((e.user_id = s.user_id)
                AND (e.day = s.day)
                AND (e.context_id = s.context_id))));

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

CREATE OR REPLACE VIEW "public"."expenditure_weekly" AS
SELECT
    expenditure.user_id,
    week_from_date (expenditure.day) AS week,
    expenditure.context_id,
    sum(COALESCE(expenditure.count, (0)::bigint)) AS count,
    sum(expenditure.minutes) AS minutes,
    sum(expenditure.tentative_count) AS tentative_count,
    sum(expenditure.tentative_minutes) AS tentative_minutes,
    sum(expenditure.declined_count) AS declined_count,
    sum(expenditure.declined_minutes) AS declined_minutes
FROM
    expenditure
GROUP BY
    expenditure.user_id,
    (week_from_date (expenditure.day)),
    expenditure.context_id;

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
    ctx.user_id,
    ctx.path,
    week_from_date (i.day) AS week,
    i.type,
    i.name,
    i.value,
    COALESCE(sum(i.count) FILTER (WHERE (i.response = 'accepted'::event_response)), (0)::bigint) AS count,
    COALESCE(sum(i.minutes) FILTER (WHERE (i.response = 'accepted'::event_response)), (0)::bigint) AS minutes,
    COALESCE(sum(i.count) FILTER (WHERE (i.response IS NULL)), (0)::bigint) AS pending_count,
    COALESCE(sum(i.minutes) FILTER (WHERE (i.response IS NULL)), (0)::bigint) AS pending_minutes
FROM (context ctx
    LEFT JOIN insight i ON (ctx.path = i.context_path))
GROUP BY
    ctx.user_id,
    ctx.path,
    (week_from_date (i.day)),
    i.type,
    i.name,
    i.value;

CREATE OR REPLACE FUNCTION public.priorities_for_week (user_id uuid, week daterange)
    RETURNS TABLE (
        id bigint,
        budget integer,
        budget_type budget_type,
        "order" text,
        order_type budget_type,
        count integer,
        minutes integer,
        tentative_count integer,
        tentative_minutes integer,
        declined_count integer,
        declined_minutes integer)
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN QUERY
    SELECT
        c.id,
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
            c.id
        FROM
            context c
        WHERE
            c.user_id = priorities_for_week.user_id
            -- Include uncategorized events
        UNION ALL
        SELECT
            NULL AS id) AS c
    LEFT JOIN ( SELECT DISTINCT ON (p.context_id)
            p.context_id,
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
            p.context_id,
            p.week DESC) AS b ON (b.context_id = c.id
            OR (b.context_id IS NULL
                AND c.id IS NULL))
        LEFT JOIN ( SELECT DISTINCT ON (p.context_id)
                p.context_id,
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
                p.context_id,
                p.week DESC) AS o ON (o.context_id = c.id
                OR (b.context_id IS NULL
                    AND c.id IS NULL))
            LEFT JOIN (
                SELECT
                    *
                FROM
                    expenditure_weekly e
                WHERE
                    e.user_id = priorities_for_week.user_id
                    AND e.week && priorities_for_week.week) AS e ON (e.context_id = c.id
                    OR (b.context_id IS NULL
                        AND c.id IS NULL));
END;
$function$;

CREATE POLICY "Users can edit their sessions" ON "public"."session" AS permissive
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

ALTER VIEW expenditure_weekly SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

