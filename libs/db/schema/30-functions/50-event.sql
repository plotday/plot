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

CREATE FUNCTION calc_seconds (r tstzrange)
    RETURNS integer
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN round(EXTRACT(epoch FROM (upper(r) - lower(r))))::integer;
END;
$function$;

CREATE OR REPLACE FUNCTION calc_all_day (at tstzrange)
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $$
DECLARE
    seconds integer = calc_seconds (at);
BEGIN
    RETURN seconds >= 60 * 23;
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
    seconds integer = calc_seconds (at);
BEGIN
    RETURN CASE WHEN seconds <= 20 THEN
        15
    WHEN seconds < 40 THEN
        30
    WHEN seconds < 50 THEN
        45
    WHEN seconds < 75 THEN
        60
    WHEN seconds < 101 THEN
        90
    WHEN seconds < 131 THEN
        120
    WHEN seconds < 161 THEN
        150
    WHEN seconds <= 180 THEN
        180
    WHEN seconds <= 300 THEN
        240
    WHEN seconds <= 420 THEN
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
    seconds integer = calc_seconds (at);
BEGIN
    RETURN seconds < 30
        OR (MOD(seconds, 30) >= 10
            AND MOD(seconds, 30) <= 15);
END;
$$;

