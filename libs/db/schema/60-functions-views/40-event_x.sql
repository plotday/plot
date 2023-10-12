CREATE OR REPLACE FUNCTION "public"."calc_attendance" (attendance public.event_attendance, response public.event_response, invitee_count integer, "start" timestamp with time zone)
    RETURNS event_attendance
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN CASE WHEN response = 'declined'::event_response THEN
        'skip'::event_attendance
    WHEN response = 'accepted'
        AND (invitee_count < 2
            OR "start" < CURRENT_TIMESTAMP) THEN
        'attend'::event_attendance
    WHEN attendance IS NULL THEN
        NULL
    WHEN response = 'accepted'::event_response THEN
        'attend'::event_attendance
    WHEN attendance = 'attend'::event_attendance
        AND response = 'tentative'::event_response THEN
        'skip'::event_attendance
    ELSE
        attendance
    END;
END;
$function$;

CREATE OR REPLACE FUNCTION "public"."calc_event_type" (at tstzrange, availability event_availability, response event_response, invitee_count integer)
    RETURNS event_type
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN CASE WHEN EXTRACT(epoch FROM (upper(at) - lower(at))) >= 60 * 60 * 23 THEN
        'note'::event_type
    WHEN invitee_count > 1
        AND (availability = 'busy'
            OR response = 'declined') THEN
        'meeting'::event_type
    ELSE
        'task'::event_type
    END;
END;
$function$;

CREATE TYPE "public"."event_internal" AS enum (
    'internal',
    'external'
);

CREATE OR REPLACE FUNCTION "public"."calc_internal" (user_domain bigint, domains bigint[])
    RETURNS event_internal
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN CASE WHEN user_domain IS NULL THEN
        NULL
    WHEN ARRAY[user_domain] = domains THEN
        'internal'::event_internal
    ELSE
        'external'::event_internal
    END;
END;
$function$;

CREATE OR REPLACE VIEW "public"."event_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    u.id AS user_id,
    min(e.id) AS id,
    e.name,
    (
        CASE WHEN EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= 60 * 60 * 23 THEN
            tstzrange(timezone(u.timezone, timezone('UTC', lower(e.at))), timezone(u.timezone, timezone('UTC', upper(e.at))), '[)'::text)
        ELSE
            e.at
        END) AS at,
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
    COALESCE(min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), 'tentative') AS response,
    calc_attendance (min(er.attendance), min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), count(DISTINCT i.email)::integer, lower(at)) AS attendance,
    (round((EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) / (60)::numeric)))::integer AS minutes,
    count(DISTINCT i.email) FILTER (WHERE (i.response = 'accepted'::event_response))::integer AS attendee_count,
count(DISTINCT i.email)::integer AS invitee_count,
min(er.ready) AS ready,
CASE WHEN min(upper(e.at)) < u.activated_at THEN
    upper(e.at)
ELSE
    min(er.reviewed)
END AS reviewed,
CASE WHEN EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= 60 * 60 * 23 THEN
    timezone(u.timezone, timezone('UTC', lower(e.at)))::date
ELSE
    (lower(e.at) at time zone u.timezone)::date
END AS day,
COALESCE(u.id = min(ct.contact_user_id) FILTER (WHERE ct.email = e.organizer_email), FALSE) AS initiated,
EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= 60 * 60 * 23 AS all_day,
calc_event_type (e.at, min(e.availability), COALESCE(min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), 'tentative'), count(DISTINCT i.email)::integer) AS type,
calc_internal (min(ct.domain_id) FILTER (WHERE (ct.contact_user_id = u.id)), array_agg(DISTINCT ct.domain_id)) AS internal,
CASE WHEN count(el.label_id) > 0 THEN
    array_agg(DISTINCT el.label_id) FILTER (WHERE (el.label_id IS NOT NULL))
ELSE
    ARRAY[]::bigint[]
END AS labels
FROM
    event e
    JOIN calendar c ON (e.calendar_id = c.id)
    JOIN account a ON (c.account_id = a.id)
    JOIN "user" u ON (a.user_id = u.id)
    LEFT JOIN response er ON (u.id = er.user_id
            AND e.provider_id = er.provider_id)
    JOIN invitee i ON (e.id = i.event_id)
    JOIN contact ct ON (ct.user_id = u.id
            AND i.email = ct.email)
    LEFT JOIN event_label el ON (e.id = el.event_id)
GROUP BY
    u.id,
    e.name,
    e.at;

-- Define a computed relation for PostgREST joins
-- https://postgrest.org/en/stable/references/api/resource_embedding.html#computed-relationships
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

CREATE OR REPLACE FUNCTION public.account (calendar)
    RETURNS SETOF account ROWS 1
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        account.*
    FROM
        account
    WHERE
        account.id = $1.account_id
$function$;

