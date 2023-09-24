SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.work_day_end ()
    RETURNS time without time zone
    LANGUAGE sql
    IMMUTABLE PARALLEL SAFE
    AS $function$
    SELECT
        '17:00'::time
$function$;

CREATE OR REPLACE FUNCTION public.work_day_start ()
    RETURNS time without time zone
    LANGUAGE sql
    IMMUTABLE PARALLEL SAFE
    AS $function$
    SELECT
        '09:00'::time
$function$;

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

ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW expenditure SET ( security_invoker = TRUE);
ALTER VIEW expenditure_monthly SET ( security_invoker = TRUE);
ALTER VIEW expenditure_rolling SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
