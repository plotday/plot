DROP POLICY "Users can view their own goals" ON "public"."goal";

ALTER TABLE "public"."goal"
    DROP CONSTRAINT "goal_category_id_fkey";

ALTER TABLE "public"."goal"
    DROP CONSTRAINT "goal_user_id_fkey";

DROP VIEW IF EXISTS "public"."balance_monthly";

DROP VIEW IF EXISTS "public"."balance_weekly";

DROP VIEW IF EXISTS "public"."goal_monthly";

DROP FUNCTION IF EXISTS "public"."goal_type_equal" (gtype goal_type, etype event_type);

DROP VIEW IF EXISTS "public"."goal_weekly";

DROP VIEW IF EXISTS "public"."category_total_monthly";

DROP VIEW IF EXISTS "public"."category_total_weekly";

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."insight_monthly";

DROP VIEW IF EXISTS "public"."prep_monthly";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."insight";

DROP VIEW IF EXISTS "public"."event_x" CASCADE;

ALTER TABLE "public"."goal"
    DROP CONSTRAINT "goal_pkey";

DROP INDEX IF EXISTS "public"."goal_pkey";

DROP INDEX IF EXISTS "public"."goal_user_id_idx";

DROP TABLE "public"."goal";

ALTER TABLE "public"."category"
    ADD COLUMN "minimize" boolean NOT NULL DEFAULT TRUE;

DROP TYPE "public"."goal_type";

CREATE OR REPLACE VIEW "public"."event_x" AS
SELECT
    u.id AS user_id,
    min(e.id) AS id,
    e.name,
    CASE WHEN calc_all_day (e.at) THEN
        tstzrange(timezone(COALESCE(u.timezone, 'America/New_York'::text), timezone('UTC'::text, lower(e.at))), timezone(COALESCE(u.timezone, 'America/New_York'::text), timezone('UTC'::text, upper(e.at))), '[)'::text)
    ELSE
        e.at
    END AS at,
    min(e.calendar_id) AS calendar_id,
    min(e.provider_id) AS provider_id,
    min(e.series) AS series,
    min(e.created_at) AS created_at,
    min(e.status) AS status,
    min(e.provider_link) AS provider_link,
    min(e.summary) AS summary,
    min(e.description) AS description,
    min(e.visibility) AS visibility,
    min(e.availability) AS availability,
    min(e.conferencing_url) AS conferencing_url,
    min(e.organizer_email) AS organizer_email,
    COALESCE(min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), 'tentative'::event_response) AS response,
    calc_attendance (min(eo.attendance), min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), (count(DISTINCT i.email))::integer, lower(e.at), ((count(DISTINCT i.email) < 2)
    AND COALESCE((u.id = min(ct.contact_user_id) FILTER (WHERE (ct.email = e.organizer_email))), FALSE)
AND (min(e.series) IS NULL))) AS attendance,
    calc_minutes (e.at) AS minutes,
    (count(DISTINCT i.email) FILTER (WHERE (i.response = 'accepted'::event_response)))::integer AS attendee_count,
(count(DISTINCT i.email))::integer AS invitee_count,
min(eo.ready) AS ready,
CASE WHEN (min(upper(e.at)) < u.activated_at) THEN
    upper(e.at)
ELSE
    min(eo.reviewed)
END AS reviewed,
CASE WHEN (EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= (((60 * 60) * 23))::numeric) THEN
    (timezone(COALESCE(u.timezone, 'America/New_York'::text), timezone('UTC'::text, lower(e.at))))::date
ELSE
    ((lower(e.at) AT TIME ZONE COALESCE(u.timezone, 'America/New_York'::text)))::date
END AS day,
COALESCE((u.id = min(ct.contact_user_id) FILTER (WHERE (ct.email = e.organizer_email))), FALSE) AS initiated,
calc_all_day (e.at) AS all_day,
calc_event_type (e.at, min(e.availability), COALESCE(min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), 'tentative'::event_response), (((count(DISTINCT i.email))::integer > 1)
    OR bool_or(e.invitees_hidden))) AS type,
calc_internal ((count(DISTINCT i.email))::integer, min(ct.domain_id) FILTER (WHERE (ct.contact_user_id = u.id)), array_agg(DISTINCT ct.domain_id)) AS internal,
bool_or(e.invitees_hidden) AS invitees_hidden,
min(cg.id) AS category_id,
text2ltree (min(ltree2text (cg.path))) AS category_path,
(min(e.series) IS NOT NULL) AS recurring,
calc_notice (min(e.created_at), e.at) AS notice,
calc_speedy (e.at) AS speedy,
calc_rounded_length (e.at) AS rounded_length,
calc_meeting_size ((count(DISTINCT i.email))::integer) AS size
FROM (((((((event e
                            JOIN calendar c ON (e.calendar_id = c.id))
                        JOIN account a ON (c.account_id = a.id))
                    JOIN "user" u ON (a.user_id = u.id))
                LEFT JOIN event_overlay eo ON (((u.id = eo.user_id)
                            AND (e.provider_id = eo.provider_id))))
            LEFT JOIN category cg ON (((u.id = cg.user_id)
                        AND (COALESCE(eo.category_id, c.category_id) = cg.id))))
        JOIN invitee i ON (e.id = i.event_id))
    JOIN contact ct ON (((ct.user_id = u.id)
                AND (i.email = ct.email))))
WHERE (c.enabled = TRUE)
GROUP BY
    u.id,
    e.name,
    e.at;

CREATE OR REPLACE VIEW "public"."gap" AS
SELECT
    gap.user_id,
    gap.day,
    (gap.at * tstzrange(((gap.day + work_day_start ()) AT TIME ZONE COALESCE("user".timezone, 'America/New_York'::text)), ((gap.day + work_day_end ()) AT TIME ZONE COALESCE("user".timezone, 'America/New_York'::text)), '[]'::text)) AS at,
    extract_minutes ((gap.at * tstzrange(((gap.day + work_day_start ()) AT TIME ZONE COALESCE("user".timezone, 'America/New_York'::text)), ((gap.day + work_day_end ()) AT TIME ZONE COALESCE("user".timezone, 'America/New_York'::text)), '[]'::text))) AS minutes
FROM ((
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
            user_1.id,
            days.day,
            tstzrange(((days.day + '1 day'::interval) AT TIME ZONE COALESCE(user_1.timezone, 'America/New_York'::text)), ((days.day + '1 day'::interval) AT TIME ZONE COALESCE(user_1.timezone, 'America/New_York'::text)), '[]'::text) AS at
        FROM ("user" user_1
        CROSS JOIN (
            SELECT
                (generate_series(((min(lower(event.at)))::date)::timestamp with time zone, ((max(upper(event.at)))::date)::timestamp with time zone, '1 day'::interval))::date AS day
            FROM
                event) days)) e
WINDOW start_window AS (PARTITION BY e.user_id ORDER BY (lower(e.at)),
    (upper(e.at))
    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)) gap
JOIN "user" ON (gap.user_id = "user".id))
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
    e.category_id,
    text2ltree (min(ltree2text (e.category_path))) AS category_path,
    e.type,
    e.attendance,
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
    e.category_id,
    e.type,
    e.attendance,
    nv.name,
    nv.value;

CREATE OR REPLACE VIEW "public"."insight_monthly" AS
SELECT
    insight.user_id,
    (date_trunc('month'::text, (insight.day)::timestamp with time zone))::date AS month,
    insight.type,
    insight.category_id,
    text2ltree (min(ltree2text (insight.category_path))) AS category_path,
    insight.attendance,
    insight.name,
    insight.value,
    sum(insight.count) AS count,
    sum(insight.minutes) AS minutes
FROM
    insight
GROUP BY
    insight.user_id,
    ((date_trunc('month'::text, (insight.day)::timestamp with time zone))::date),
    insight.type,
    insight.category_id,
    insight.attendance,
    insight.name,
    insight.value;

CREATE OR REPLACE VIEW "public"."prep_monthly" AS
SELECT
    e.user_id,
    (date_trunc('month'::text, (e.day)::timestamp with time zone))::date AS month,
    count(*) FILTER (WHERE (lower(e.at) < CURRENT_TIMESTAMP)) AS past_count,
count(*) FILTER (WHERE ((lower(e.at) < CURRENT_TIMESTAMP)
AND (e.ready < lower(e.at)))) AS past_ready_count,
count(*) FILTER (WHERE ((upper(e.at) < CURRENT_TIMESTAMP)
AND (e.reviewed < (upper(e.at) + '2 days'::interval)))) AS past_reviewed_count,
round((avg(EXTRACT(epoch FROM (COALESCE(e.reviewed, CURRENT_TIMESTAMP) - upper(e.at)))) FILTER (WHERE (upper(e.at) < CURRENT_TIMESTAMP)) / (60)::numeric)) AS review_time
FROM
    event_x e
WHERE (e.type = 'meeting'::event_type)
GROUP BY
    e.user_id,
    ((date_trunc('month'::text, (e.day)::timestamp with time zone))::date);

CREATE OR REPLACE VIEW "public"."category_total_monthly" AS
SELECT
    c.user_id,
    c.id,
    c.path,
    (date_trunc('month'::text, (i.day)::timestamp with time zone))::date AS month,
    i.type,
    sum(i.count) FILTER (WHERE (i.attendance = 'attend'::event_attendance)) AS count,
sum(i.minutes) FILTER (WHERE (i.attendance = 'attend'::event_attendance)) AS minutes,
sum(i.count) FILTER (WHERE (i.attendance IS NULL)) AS pending_count,
sum(i.minutes) FILTER (WHERE (i.attendance IS NULL)) AS pending_minutes
FROM (category c
    LEFT JOIN insight i ON (c.id = i.category_id))
WHERE (i.name = 'Total'::text)
GROUP BY
    c.user_id,
    c.id,
    c.path,
    (date_trunc('month'::text, (i.day)::timestamp with time zone)),
    i.type;

CREATE OR REPLACE VIEW "public"."category_total_weekly" AS
SELECT
    c.user_id,
    c.id,
    c.path,
    (date_trunc('week'::text, (i.day)::timestamp with time zone))::date AS week,
    i.type,
    sum(i.count) FILTER (WHERE (i.attendance = 'attend'::event_attendance)) AS count,
sum(i.minutes) FILTER (WHERE (i.attendance = 'attend'::event_attendance)) AS minutes,
sum(i.count) FILTER (WHERE (i.attendance IS NULL)) AS pending_count,
sum(i.minutes) FILTER (WHERE (i.attendance IS NULL)) AS pending_minutes
FROM (category c
    LEFT JOIN insight i ON (c.id = i.category_id))
WHERE (i.name = 'Total'::text)
GROUP BY
    c.user_id,
    c.id,
    c.path,
    (date_trunc('week'::text, (i.day)::timestamp with time zone)),
    i.type;

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

ALTER VIEW insight_monthly SET (security_invoker = TRUE);

ALTER VIEW category_total_weekly SET (security_invoker = TRUE);

ALTER VIEW category_total_monthly SET (security_invoker = TRUE);

-- ALTER VIEW goal_weekly SET ( security_invoker = TRUE);
-- ALTER VIEW goal_monthly SET ( security_invoker = TRUE);
-- ALTER VIEW balance_weekly SET ( security_invoker = TRUE);
-- ALTER VIEW balance_monthly SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW prep_monthly SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

