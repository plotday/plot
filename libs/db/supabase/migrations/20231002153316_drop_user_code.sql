DROP VIEW IF EXISTS "public"."expenditure_monthly" CASCADE;

DROP VIEW IF EXISTS "public"."expenditure_rolling";

DROP VIEW IF EXISTS "public"."gap_daily";

DROP VIEW IF EXISTS "public"."gap_monthly";

DROP VIEW IF EXISTS "public"."invitation_admin";

DROP VIEW IF EXISTS "public"."prep_monthly";

DROP VIEW IF EXISTS "public"."waitlist_admin";

DROP VIEW IF EXISTS "public"."expenditure";

DROP VIEW IF EXISTS "public"."gap";

DROP VIEW IF EXISTS "public"."event_x" CASCADE;

DROP INDEX IF EXISTS "public"."user_code_key";

ALTER TABLE "public"."user"
    DROP COLUMN "code";

CREATE OR REPLACE VIEW "public"."event_x" AS
SELECT
    u.id AS user_id,
    min(e.id) AS id,
    e.name,
    CASE WHEN (EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= (((60 * 60) * 23))::numeric) THEN
        tstzrange(timezone(u.timezone, timezone('UTC'::text, lower(e.at))), timezone(u.timezone, timezone('UTC'::text, upper(e.at))), '[)'::text)
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
    min(e.organizer) AS organizer,
    COALESCE(min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), 'tentative'::event_response) AS response,
    calc_attendance (min(er.attendance), min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), (count(DISTINCT i.contact_id))::integer, lower(e.at)) AS attendance,
    (round((EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) / (60)::numeric)))::integer AS minutes,
    (count(DISTINCT i.contact_id) FILTER (WHERE (i.response = 'accepted'::event_response)))::integer AS attendee_count,
(count(DISTINCT i.contact_id))::integer AS invitee_count,
min(er.ready) AS ready,
min(er.reviewed) AS reviewed,
CASE WHEN (EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= (((60 * 60) * 23))::numeric) THEN
    (timezone(u.timezone, timezone('UTC'::text, lower(e.at))))::date
ELSE
    ((lower(e.at) AT TIME ZONE u.timezone))::date
END AS day,
COALESCE((u.id = min(ct.contact_user_id) FILTER (WHERE (ct.id = e.organizer))), FALSE) AS initiated,
(EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= (((60 * 60) * 23))::numeric) AS all_day,
calc_event_type (e.at, min(e.availability), COALESCE(min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), 'tentative'::event_response), (count(DISTINCT i.contact_id))::integer) AS type,
calc_internal (min(ct.domain_id) FILTER (WHERE (ct.contact_user_id = u.id)), array_agg(DISTINCT ct.domain_id)) AS internal,
CASE WHEN (count(el.label_id) > 0) THEN
    array_agg(DISTINCT el.label_id) FILTER (WHERE (el.label_id IS NOT NULL))
ELSE
    ARRAY[]::bigint[]
END AS labels
FROM (((((((event e
                            JOIN calendar c ON (e.calendar_id = c.id))
                        JOIN account a ON (c.account_id = a.id))
                    JOIN "user" u ON (a.user_id = u.id))
                LEFT JOIN response er ON (((u.id = er.user_id)
                            AND (e.provider_id = er.provider_id))))
            JOIN invitee i ON (e.id = i.event_id))
        JOIN contact ct ON (i.contact_id = ct.id))
    LEFT JOIN event_label el ON (e.id = el.event_id))
GROUP BY
    u.id,
    e.name,
    e.at;

CREATE OR REPLACE VIEW "public"."expenditure" AS
SELECT
    e.user_id,
    e.day,
    el.label_id,
    e.attendance,
    (count(*))::integer AS event_count,
    (sum(e.minutes))::integer AS minutes,
    (count(*) FILTER (WHERE (e.initiated
            AND (el.label_id <> 24))))::integer AS org_event_count,
(sum(e.minutes * e.invitee_count) FILTER (WHERE (e.initiated
        AND (el.label_id <> 24))))::integer AS org_minutes
FROM (event_x e
    JOIN event_label el ON (e.id = el.event_id))
WHERE (e.status <> 'cancelled'::event_status)
GROUP BY
    e.user_id,
    e.day,
    el.label_id,
    e.attendance;

CREATE OR REPLACE VIEW "public"."expenditure_monthly" AS
SELECT
    e.user_id,
    (date_trunc('month'::text, (e.day)::timestamp with time zone))::date AS month,
    e.label_id,
    e.attendance,
    sum(e.event_count) AS event_count,
    sum(e.minutes) AS minutes,
    sum(e.org_event_count) AS org_event_count,
    sum(e.org_minutes) AS org_minutes
FROM
    expenditure e
GROUP BY
    e.user_id,
    ((date_trunc('month'::text, (e.day)::timestamp with time zone))::date),
    e.label_id,
    e.attendance;

CREATE OR REPLACE VIEW "public"."expenditure_rolling" AS
SELECT
    COALESCE(expenditure.user_id, expenditure_expiries.user_id) AS user_id,
    COALESCE(expenditure.day, expenditure_expiries.day) AS day,
    COALESCE(expenditure.label_id, expenditure_expiries.label_id) AS label_id,
    COALESCE(expenditure.attendance, expenditure_expiries.attendance) AS attendance,
    sum(COALESCE(expenditure.event_count, 0)) OVER w AS event_count,
    sum(COALESCE(expenditure.minutes, 0)) OVER w AS minutes,
    sum(COALESCE(expenditure.org_event_count, 0)) OVER w AS org_event_count,
    sum(COALESCE(expenditure.org_minutes, 0)) OVER w AS org_minutes
FROM (expenditure
    FULL JOIN (
        SELECT
            expenditure_1.user_id, (expenditure_1.day + '28 days'::interval)::date AS day,
            expenditure_1.label_id,
            expenditure_1.attendance
        FROM
            expenditure expenditure_1) expenditure_expiries ON (((expenditure.user_id = expenditure_expiries.user_id)
                    AND (expenditure.day = expenditure_expiries.day)
                    AND (expenditure.label_id = expenditure_expiries.label_id)
                    AND (expenditure.attendance = expenditure_expiries.attendance))))
WINDOW w AS (PARTITION BY COALESCE(expenditure.user_id, expenditure_expiries.user_id),
    COALESCE(expenditure.label_id, expenditure_expiries.label_id),
    COALESCE(expenditure.attendance, expenditure_expiries.attendance)
ORDER BY
    COALESCE(expenditure.day, expenditure_expiries.day)
    RANGE BETWEEN '27 days'::interval PRECEDING AND CURRENT ROW)
ORDER BY
    COALESCE(expenditure.day, expenditure_expiries.day);

CREATE OR REPLACE VIEW "public"."gap" AS
SELECT
    gap.user_id,
    gap.day,
    (gap.at * tstzrange(((gap.day + work_day_start ()) AT TIME ZONE "user".timezone), ((gap.day + work_day_end ()) AT TIME ZONE "user".timezone), '[]'::text)) AS at,
    extract_minutes ((gap.at * tstzrange(((gap.day + work_day_start ()) AT TIME ZONE "user".timezone), ((gap.day + work_day_end ()) AT TIME ZONE "user".timezone), '[]'::text))) AS minutes
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
            tstzrange(((days.day + '1 day'::interval) AT TIME ZONE user_1.timezone), ((days.day + '1 day'::interval) AT TIME ZONE user_1.timezone), '[]'::text) AS at
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

CREATE OR REPLACE VIEW "public"."invitation_admin" AS
SELECT
    min(i.id) AS id,
    min(i.created_at) AS created_at,
    min(i.code) AS code,
    min(i.remaining) AS remaining,
    count(u.invitation) AS uses
FROM (invitation i
    LEFT JOIN "user" u ON (u.invitation = i.code))
GROUP BY
    i.id;

CREATE OR REPLACE VIEW "public"."prep_monthly" AS
SELECT
    e.user_id,
    (date_trunc('month'::text, (e.day)::timestamp with time zone))::date AS month,
    count(*) FILTER (WHERE (lower(e.at) < CURRENT_TIMESTAMP)) AS past_count,
count(*) FILTER (WHERE ((lower(e.at) < CURRENT_TIMESTAMP)
AND (e.ready < lower(e.at)))) AS past_ready_count,
count(*) FILTER (WHERE ((lower(e.at) < CURRENT_TIMESTAMP)
AND (e.reviewed IS NOT NULL))) AS past_reviewed_count,
round((avg(EXTRACT(epoch FROM (COALESCE(e.reviewed, CURRENT_TIMESTAMP) - lower(e.at)))) FILTER (WHERE (lower(e.at) < CURRENT_TIMESTAMP)) / (60)::numeric)) AS review_time
FROM
    event_x e
WHERE (e.type = 'meeting'::event_type)
GROUP BY
    e.user_id,
    ((date_trunc('month'::text, (e.day)::timestamp with time zone))::date);

CREATE OR REPLACE VIEW "public"."waitlist_admin" AS
SELECT
    min(u.id) AS id,
    min(u.created_at) AS created_at,
    min(u.email) AS email,
    CASE WHEN (min(c.sync_error) IS NOT NULL) THEN
        'sync_error'::text
    WHEN (min(u.status) = 'active'::user_status) THEN
        'active'::text
    WHEN (count(*) FILTER (WHERE ((a.credentials -> 'refresh_token'::text) IS NOT NULL)) > 0) THEN
        'synced'::text
    ELSE
        'waitlisted'::text
    END AS status,
    array_agg(DISTINCT a.email) FILTER (WHERE (a.email IS NOT NULL)) AS sync_accounts,
array_agg(c.sync_error) FILTER (WHERE (c.sync_error IS NOT NULL)) AS sync_error,
array_agg(DISTINCT a.provider) FILTER (WHERE (a.provider IS NOT NULL)) AS provider,
u.invitation,
count(e.id) AS event_count
FROM ((("user" u
        LEFT JOIN account a ON (((u.id = a.user_id)
                    AND (a.credentials IS NOT NULL))))
    LEFT JOIN calendar c ON (c.account_id = a.id))
    LEFT JOIN event e ON (e.calendar_id = c.id))
GROUP BY
    u.id;

DROP FUNCTION IF EXISTS "public"."random_code" ();

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

CREATE OR REPLACE FUNCTION public.event_label_ids (e event_x)
    RETURNS bigint[]
    LANGUAGE plpgsql
    STABLE
    AS $function$
DECLARE
    result bigint[] = '{}'::bigint[];
BEGIN
    IF e.type <> 'meeting' THEN
        RETURN result;
    END IF;
    IF e.initiated = TRUE THEN
        result := result || 1;
    END IF;
    result := result || CASE WHEN e.invitee_count = 2 THEN
        2
    WHEN e.invitee_count <= 4 THEN
        3
    WHEN e.invitee_count <= 7 THEN
        4
    WHEN e.invitee_count <= 15 THEN
        5
    WHEN e.invitee_count <= 30 THEN
        6
    ELSE
        7
    END;
    IF e.internal = 'internal'::event_internal THEN
        result := result || 8;
    END IF;
    IF e.internal = 'external'::event_internal THEN
        result := result || 9;
    END IF;
    result := result || CASE WHEN e.minutes <= 20 THEN
        10
    WHEN e.minutes < 40 THEN
        11
    WHEN e.minutes < 50 THEN
        12
    WHEN e.minutes < 75 THEN
        13
    WHEN e.minutes < 101 THEN
        14
    WHEN e.minutes < 131 THEN
        15
    WHEN e.minutes < 161 THEN
        16
    WHEN e.minutes <= 180 THEN
        17
    WHEN e.minutes <= 300 THEN
        18
    WHEN e.minutes <= 420 THEN
        19
    ELSE
        20
    END;
    IF e.series IS NOT NULL THEN
        result := result || 21;
    END IF;
    IF e.created_at IS NOT NULL AND EXTRACT(EPOCH FROM (LOWER(e.at) - e.created_at)) < 18 * 60 * 60 THEN
        result := result || 22;
    END IF;
    IF e.minutes < 30 OR (MOD(e.minutes, 30) >= 10 AND MOD(e.minutes, 30) <= 15) THEN
        result := result || 23;
    END IF;
    IF e.initiated = TRUE THEN
        result := result || 24;
    END IF;
    RETURN result;
END;
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

CREATE OR REPLACE FUNCTION public.label (expenditure_monthly)
    RETURNS SETOF label
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        *
    FROM
        label
    WHERE
        id = $1.label_id
$function$;

REVOKE ALL ON waitlist_admin FROM PUBLIC;

GRANT SELECT ON waitlist_admin TO internal_admin;

