DROP FUNCTION IF EXISTS "public"."accounts" (calendar);

DROP FUNCTION IF EXISTS "public"."calendars" (event_x);

DROP FUNCTION IF EXISTS "public"."label" (event_x);

CREATE INDEX event_at_idx ON public.event USING spgist (at);

CREATE INDEX invitee_event_id_idx ON public.invitee USING btree (event_id);

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.account (calendar)
    RETURNS SETOF account
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        account.*
    FROM
        account
    WHERE
        account.id = $1.account_id
$function$;

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

CREATE OR REPLACE FUNCTION public.event_label_matches (e event_x)
    RETURNS SETOF bigint
    LANGUAGE plpgsql
    STABLE
    AS $function$
BEGIN
    IF e.type <> 'meeting' THEN
        RETURN;
    END IF;
    IF e.initiated = TRUE THEN
        RETURN NEXT 1;
    END IF;
    RETURN NEXT CASE WHEN e.invitee_count = 2 THEN
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
        RETURN NEXT 8;
    END IF;
    IF e.internal = 'external'::event_internal THEN
        RETURN NEXT 9;
    END IF;
    RETURN NEXT CASE WHEN e.minutes <= 20 THEN
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
        RETURN NEXT 21;
    END IF;
    IF e.created_at IS NOT NULL AND EXTRACT(EPOCH FROM (LOWER(e.at) - e.created_at)) < 18 * 60 * 60 THEN
        RETURN NEXT 22;
    END IF;
    IF e.minutes < 30 OR (MOD(e.minutes, 30) >= 10 AND MOD(e.minutes, 30) <= 15) THEN
        RETURN NEXT 23;
    END IF;
    IF e.initiated = TRUE THEN
        RETURN NEXT 24;
    END IF;
    -- RETURN QUERY
    -- SELECT
    --     *
    -- FROM
    --     event_label
    -- WHERE
    --     provider_id = e.provider_id;
    RETURN;
END;
$function$;

CREATE OR REPLACE VIEW "public"."event_x2" AS
SELECT
    min(e.user_id) AS user_id,
    min(e.id) AS id,
    min(e.name) AS name,
    tstzrange(min(lower(e.at)), min(upper(e.at)), '[)'::text) AS at,
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
    min(e.response) AS response,
    min(e.attendance) AS attendance,
    min(e.minutes) AS minutes,
    min(e.attendee_count) AS attendee_count,
    min(e.invitee_count) AS invitee_count,
    bool_or(e.ready) AS ready,
    bool_or(e.reviewed) AS reviewed,
    min(e.day) AS day,
    bool_or(e.initiated) AS initiated,
    bool_or(e.all_day) AS all_day,
    min(e.type) AS type,
    min(e.internal) AS internal,
    array_agg((l.l)::integer) AS labels
FROM (event_x e
    CROSS JOIN LATERAL event_label_matches (e.*) l (l))
GROUP BY
    e.id;

CREATE OR REPLACE FUNCTION public.invitee (event_x2)
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

ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."event_label" SET (security_invoker = TRUE);

ALTER VIEW "public"."event_x2" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW expenditure SET (security_invoker = TRUE);

ALTER VIEW expenditure_monthly SET (security_invoker = TRUE);

ALTER VIEW expenditure_rolling SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

