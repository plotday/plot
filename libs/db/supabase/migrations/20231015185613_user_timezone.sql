ALTER TABLE "public"."user"
    ALTER COLUMN "timezone" DROP DEFAULT;

ALTER TABLE "public"."user"
    ALTER COLUMN "timezone" DROP NOT NULL;

CREATE OR REPLACE VIEW "public"."event_x" AS
SELECT
    u.id AS user_id,
    min(e.id) AS id,
    e.name,
    CASE WHEN (EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= (((60 * 60) * 23))::numeric) THEN
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
    calc_attendance (min(er.attendance), min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), (count(DISTINCT i.email))::integer, lower(e.at)) AS attendance,
    (round((EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) / (60)::numeric)))::integer AS minutes,
    (count(DISTINCT i.email) FILTER (WHERE (i.response = 'accepted'::event_response)))::integer AS attendee_count,
(count(DISTINCT i.email))::integer AS invitee_count,
min(er.ready) AS ready,
CASE WHEN (min(upper(e.at)) < u.activated_at) THEN
    upper(e.at)
ELSE
    min(er.reviewed)
END AS reviewed,
CASE WHEN (EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= (((60 * 60) * 23))::numeric) THEN
    (timezone(COALESCE(u.timezone, 'America/New_York'::text), timezone('UTC'::text, lower(e.at))))::date
ELSE
    ((lower(e.at) AT TIME ZONE COALESCE(u.timezone, 'America/New_York'::text)))::date
END AS day,
COALESCE((u.id = min(ct.contact_user_id) FILTER (WHERE (ct.email = e.organizer_email))), FALSE) AS initiated,
(EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= (((60 * 60) * 23))::numeric) AS all_day,
calc_event_type (e.at, min(e.availability), COALESCE(min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), 'tentative'::event_response), (((count(DISTINCT i.email))::integer > 1)
    OR bool_or(e.invitees_hidden))) AS type,
calc_internal (min(ct.domain_id) FILTER (WHERE (ct.contact_user_id = u.id)), array_agg(DISTINCT ct.domain_id)) AS internal,
CASE WHEN (count(el.label_id) > 0) THEN
    array_agg(DISTINCT el.label_id) FILTER (WHERE (el.label_id IS NOT NULL))
ELSE
    ARRAY[]::bigint[]
END AS labels,
bool_or(e.invitees_hidden) AS invitees_hidden
FROM (((((((event e
                            JOIN calendar c ON (e.calendar_id = c.id))
                        JOIN account a ON (c.account_id = a.id))
                    JOIN "user" u ON (a.user_id = u.id))
                LEFT JOIN response er ON (((u.id = er.user_id)
                            AND (e.provider_id = er.provider_id))))
            JOIN invitee i ON (e.id = i.event_id))
        JOIN contact ct ON (((ct.user_id = u.id)
                    AND (i.email = ct.email))))
    LEFT JOIN event_label el ON (e.id = el.event_id))
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

ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW expenditure SET ( security_invoker = TRUE);
ALTER VIEW expenditure_monthly SET ( security_invoker = TRUE);
ALTER VIEW expenditure_rolling SET ( security_invoker = TRUE);
ALTER VIEW prep_monthly SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
