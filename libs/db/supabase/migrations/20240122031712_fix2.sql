DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."insight_weekly";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."insight";

DROP VIEW IF EXISTS "public"."event_x" CASCADE;

SET check_function_bodies = OFF;

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
            (((((((
                CASE WHEN (r_1.series IS NOT NULL) THEN
                    128
                ELSE
                    0
                END + CASE WHEN (r_1.name IS NOT NULL) THEN
                    64
                ELSE
                    0
                END) + CASE WHEN (r_1.invitees IS NOT NULL) THEN
                32
            ELSE
                0
            END) + CASE WHEN (r_1.invitee_domain IS NOT NULL) THEN
            16
        ELSE
            0
        END) + CASE WHEN (r_1.account_id IS NOT NULL) THEN
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
            AND ((r_1.account_id IS NULL)
                OR (e.account_id = r_1.account_id))
            AND ((r_1.calendar_id IS NULL)
                OR (e.calendar_id = r_1.calendar_id))
            AND ((r_1.internal IS NULL)
                OR (e.internal = r_1.internal))
            AND ((r_1.type IS NULL)
                OR (e.type = r_1.type)))
    ORDER BY
        (((((((
                                    CASE WHEN (r_1.series IS NOT NULL) THEN
                                        128
                                    ELSE
                                        0
                                    END + CASE WHEN (r_1.name IS NOT NULL) THEN
                                        64
                                    ELSE
                                        0
                                    END) + CASE WHEN (r_1.invitees IS NOT NULL) THEN
                                    32
                                ELSE
                                    0
                                END) + CASE WHEN (r_1.invitee_domain IS NOT NULL) THEN
                                16
                            ELSE
                                0
                            END) + CASE WHEN (r_1.account_id IS NOT NULL) THEN
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

