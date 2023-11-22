CREATE OR REPLACE FUNCTION calc_minutes (at tstzrange)
    RETURNS integer
    LANGUAGE plpgsql
    STABLE
    AS $$
BEGIN
    RETURN (round((EXTRACT(epoch FROM (upper(at) - lower(at))) / (60)::numeric)))::integer;
END;
$$;

CREATE OR REPLACE FUNCTION calc_all_day (at tstzrange)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    AS $$
DECLARE
    minutes integer = calc_minutes (at);
BEGIN
    RETURN minutes >= 60 * 23;
END;
$$;

CREATE OR REPLACE FUNCTION "public"."calc_event_type" (at tstzrange, availability event_availability, response event_response, has_invitees boolean)
    RETURNS event_type
    LANGUAGE plpgsql
    AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION "public"."calc_internal" (invitee_count integer, user_domain bigint, domains bigint[])
    RETURNS event_internal
    LANGUAGE plpgsql
    AS $function$
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
$function$;

CREATE TYPE "public"."meeting_size" AS enum (
    '1:1',
    'Small',
    'Medium',
    'Large',
    'XL',
    'XXL'
);

CREATE OR REPLACE FUNCTION calc_meeting_size (invitee_count integer)
    RETURNS text
    LANGUAGE plpgsql
    STABLE
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

CREATE OR REPLACE FUNCTION calc_rounded_length (at tstzrange)
    RETURNS integer
    LANGUAGE plpgsql
    STABLE
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

CREATE OR REPLACE FUNCTION calc_notice (created_at timestamp with time zone, at tstzrange)
    RETURNS integer
    LANGUAGE plpgsql
    STABLE
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

CREATE OR REPLACE FUNCTION calc_speedy (at tstzrange)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    AS $$
DECLARE
    minutes integer = calc_minutes (at);
BEGIN
    RETURN minutes < 30
        OR (MOD(minutes, 30) >= 10
            AND MOD(minutes, 30) <= 15);
END;
$$;

CREATE OR REPLACE VIEW "public"."event_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
WITH event_x1 AS (
    SELECT
        u.id AS user_id,
        min(e.id) AS id,
        e.name,
        (
            CASE WHEN calc_all_day (e.at) THEN
                tstzrange(timezone(COALESCE(u.timezone, 'America/New_York'), timezone('UTC', lower(e.at))), timezone(COALESCE(u.timezone, 'America/New_York'), timezone('UTC', upper(e.at))), '[)'::text)
            ELSE
                e.at
            END) AS at,
        min(e.calendar_id) AS calendar_id,
        min(e.provider_id) AS provider_id,
        COALESCE(min(e.series), min(e.provider_id)) AS series,
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
        calc_minutes (e.at) AS minutes,
        count(DISTINCT i.email) FILTER (WHERE (i.response = 'accepted'::event_response))::integer AS attendee_count,
    count(DISTINCT i.email)::integer AS invitee_count,
    CASE WHEN EXTRACT(epoch FROM (upper(e.at) - lower(e.at))) >= 60 * 60 * 23 THEN
        timezone(COALESCE(u.timezone, 'America/New_York'), timezone('UTC', lower(e.at)))::date
    ELSE
        (lower(e.at) at time zone COALESCE(u.timezone, 'America/New_York'))::date
    END AS day,
    COALESCE(u.id = min(ct.contact_user_id) FILTER (WHERE ct.email = e.organizer_email), FALSE) AS initiated,
    calc_all_day (e.at) AS all_day,
    calc_event_type (e.at, min(e.availability), COALESCE(min(i.response) FILTER (WHERE (ct.contact_user_id = u.id)), 'tentative'), count(DISTINCT i.email)::integer > 1
    OR bool_or(e.invitees_hidden)) AS type,
    calc_internal (count(DISTINCT i.email)::integer, min(ct.domain_id) FILTER (WHERE (ct.contact_user_id = u.id)), array_agg(DISTINCT ct.domain_id)) AS internal,
    array_agg(DISTINCT i.email ORDER BY i.email) AS invitees,
    array_agg(DISTINCT split_part(i.email, '@', 2)
    ORDER BY split_part(i.email, '@', 2)) AS invitee_domains,
    bool_or(e.invitees_hidden) AS invitees_hidden,
    min(e.series) IS NOT NULL AS recurring,
    calc_notice (min(e.created_at), e.at) AS notice,
    calc_speedy (e.at) AS speedy,
    calc_rounded_length (e.at) AS rounded_length,
    calc_meeting_size (count(DISTINCT i.email)::integer) AS size
FROM
    event e
    JOIN calendar c ON (e.calendar_id = c.id)
    JOIN account a ON (c.account_id = a.id)
    JOIN "user" u ON (a.user_id = u.id)
    JOIN invitee i ON (e.id = i.event_id)
    JOIN contact ct ON (ct.user_id = u.id
            AND i.email = ct.email)
    WHERE
        c.enabled = TRUE
    GROUP BY
        u.id,
        e.name,
        e.at
)
SELECT
    e.*,
    cg.id AS category_id,
    cg.path AS category_path
FROM
    event_x1 e
    LEFT JOIN LATERAL (
        SELECT
            category_id,
            CASE WHEN series IS NOT NULL THEN
                64
            ELSE
                0
            END + CASE WHEN name IS NOT NULL THEN
                32
            ELSE
                0
            END + CASE WHEN invitees IS NOT NULL THEN
                16
            ELSE
                0
            END + CASE WHEN invitee_domain IS NOT NULL THEN
                8
            ELSE
                0
            END + CASE WHEN calendar_id IS NOT NULL THEN
                4
            ELSE
                0
            END + CASE WHEN internal IS NOT NULL THEN
                2
            ELSE
                0
            END + CASE WHEN type IS NOT NULL THEN
                1
            ELSE
                0
            END AS priority
        FROM
            event_rule er
        WHERE
            e.user_id = er.user_id
            AND (er.series IS NULL
                OR e.series = er.series)
            AND (er.name IS NULL
                OR e.name = er.name)
            AND (er.invitees IS NULL
                OR e.invitees = er.invitees)
            AND (er.invitee_domain IS NULL
                OR e.invitee_domains @> ARRAY[er.invitee_domain])
            AND (er.calendar_id IS NULL
                OR e.calendar_id = er.calendar_id)
            AND (er.internal IS NULL
                OR e.internal = er.internal)
            AND (er.type IS NULL
                OR e.type = er.type)
        ORDER BY
            priority DESC,
            created_at DESC
        LIMIT 1) er ON TRUE
    LEFT JOIN category cg ON (e.user_id = cg.user_id
            AND er.category_id = cg.id);

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

