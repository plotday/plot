SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.extract_minutes (r tstzrange)
    RETURNS integer
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN round((EXTRACT(epoch FROM (upper(r) - lower(r))) / (60)::numeric))::integer;
END;
$function$;

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
    calc_attendance (min(er.attendance), min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), (count(DISTINCT i.contact_id))::integer) AS attendance,
    (round((EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) / (60)::numeric)))::integer AS minutes,
    (count(DISTINCT i.contact_id) FILTER (WHERE (i.response = 'accepted'::event_response)))::integer AS attendee_count,
(count(DISTINCT i.contact_id))::integer AS invitee_count,
COALESCE(bool_or(er.ready), FALSE) AS ready,
COALESCE(bool_or(er.reviewed), FALSE) AS reviewed,
CASE WHEN (EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= (((60 * 60) * 23))::numeric) THEN
    (timezone(u.timezone, timezone('UTC'::text, lower(e.at))))::date
ELSE
    ((lower(e.at) AT TIME ZONE u.timezone))::date
END AS day,
COALESCE((u.id = min(ct.contact_user_id) FILTER (WHERE (ct.id = e.organizer))), FALSE) AS initiated
FROM ((((((event e
                        JOIN calendar c ON (e.calendar_id = c.id))
                    JOIN account a ON (c.account_id = a.id))
                JOIN "user" u ON (a.user_id = u.id))
            LEFT JOIN response er ON (((u.id = er.user_id)
                        AND (e.provider_id = er.provider_id))))
        JOIN invitee i ON (e.id = i.event_id))
    JOIN contact ct ON (i.contact_id = ct.id))
GROUP BY
    u.id,
    e.name,
    e.at;

CREATE OR REPLACE VIEW "public"."gap" AS
SELECT
    gap.user_id,
    gap.day,
    (gap.at * tstzrange(((gap.day + '09:00:00'::time WITHOUT time zone) AT TIME ZONE "user".timezone), ((gap.day + '17:30:00'::time WITHOUT time zone) AT TIME ZONE "user".timezone), '[]'::text)) AS at,
    extract_minutes ((gap.at * tstzrange(((gap.day + '09:00:00'::time WITHOUT time zone) AT TIME ZONE "user".timezone), ((gap.day + '17:30:00'::time WITHOUT time zone) AT TIME ZONE "user".timezone), '[]'::text))) AS minutes
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
            WHERE ((event_x.minutes < (60 * 23))
                AND (event_x.invitee_count > 1)
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

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW expenditure SET (security_invoker = TRUE);

ALTER VIEW expenditure_monthly SET (security_invoker = TRUE);

ALTER VIEW expenditure_rolling SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

