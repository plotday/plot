CREATE OR REPLACE FUNCTION is_week (p_week daterange)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    IMMUTABLE
    AS $$
BEGIN
    RETURN p_week IS NULL
        OR EXTRACT(DOW FROM lower(p_week)) = 0
        AND upper(p_week) - lower(p_week) = 7;
END;
$$;

CREATE OR REPLACE FUNCTION calc_minutes (at tstzrange)
    RETURNS integer
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
BEGIN
    RETURN (round((EXTRACT(epoch FROM (upper(at) - lower(at))) / (60)::numeric)))::integer;
END;
$$;

CREATE OR REPLACE FUNCTION calc_all_day (at tstzrange)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
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
    IMMUTABLE
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
    IMMUTABLE
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
    IMMUTABLE
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
    IMMUTABLE
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
    IMMUTABLE
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
    IMMUTABLE
    AS $$
DECLARE
    minutes integer = calc_minutes (at);
BEGIN
    RETURN minutes < 30
        OR (MOD(minutes, 30) >= 10
            AND MOD(minutes, 30) <= 15);
END;
$$;

