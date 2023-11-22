DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."category_total_weekly";

DROP VIEW IF EXISTS "public"."goal_weekly";

SET check_function_bodies = OFF;

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

CREATE OR REPLACE VIEW "public"."category_total_monthly" AS
SELECT
    c.user_id,
    c.id,
    c.path,
    (date_trunc('month'::text, (i.day)::timestamp with time zone))::date AS month,
    i.type,
    sum(i.count) FILTER (WHERE (i.attendance = 'attend'::event_attendance)) AS count,
sum(i.minutes) FILTER (WHERE (i.attendance = 'attend'::event_attendance)) AS minutes,
sum(i.count) FILTER (WHERE (i.attendance IS NULL)) AS pending_count,
sum(i.minutes) FILTER (WHERE (i.attendance IS NULL)) AS pending_minutes
FROM (category c
    LEFT JOIN insight i ON (c.id = i.category_id))
WHERE (i.name = 'Total'::text)
GROUP BY
    c.user_id,
    c.id,
    c.path,
    (date_trunc('month'::text, (i.day)::timestamp with time zone)),
    i.type;

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

CREATE OR REPLACE FUNCTION public.week_days_in_month (week date, month date)
    RETURNS integer
    LANGUAGE plpgsql
    AS $function$
BEGIN
    RETURN CASE WHEN week < month THEN
        week + 7 - month
    ELSE
        LEAST (7, (month + INTERVAL '1 MONTH')::date - week)
    END;
END;
$function$;

CREATE OR REPLACE VIEW "public"."category_total_weekly" AS
SELECT
    c.user_id,
    c.id,
    c.path,
    (date_trunc('week'::text, (i.day)::timestamp with time zone))::date AS week,
    i.type,
    sum(i.count) FILTER (WHERE (i.attendance = 'attend'::event_attendance)) AS count,
sum(i.minutes) FILTER (WHERE (i.attendance = 'attend'::event_attendance)) AS minutes,
sum(i.count) FILTER (WHERE (i.attendance IS NULL)) AS pending_count,
sum(i.minutes) FILTER (WHERE (i.attendance IS NULL)) AS pending_minutes
FROM (category c
    LEFT JOIN insight i ON (c.id = i.category_id))
WHERE (i.name = 'Total'::text)
GROUP BY
    c.user_id,
    c.id,
    c.path,
    (date_trunc('week'::text, (i.day)::timestamp with time zone)),
    i.type;

CREATE OR REPLACE VIEW "public"."goal_weekly" AS
SELECT
    g.user_id,
    (w.week)::date AS week,
    c.id AS category_id,
    text2ltree (min(ltree2text (c.path))) AS category_path,
    g.type,
    sum(g.weekly_minutes) AS minutes
FROM ((generate_series(((date_trunc('week'::text, (CURRENT_DATE - '1 year'::interval)))::date)::timestamp with time zone, ((CURRENT_DATE + '1 year'::interval)::date)::timestamp with time zone, '7 days'::interval) w (week)
        LEFT JOIN goal g ON (((w.week)::date <@ g.at)))
    LEFT JOIN category c ON (((g.user_id = c.user_id)
                AND (g.category_id = c.id))))
GROUP BY
    g.user_id,
    w.week,
    c.id,
    g.type;

CREATE OR REPLACE VIEW "public"."balance_weekly" AS
SELECT
    g.user_id,
    g.week,
    g.category_id,
    g.category_path,
    g.type,
    sum((g.minutes - COALESCE(c.minutes, (0)::bigint))) OVER w AS minutes,
    sum(c.pending_minutes) OVER w AS pending_minutes
FROM (goal_weekly g
    LEFT JOIN category_total_weekly c ON (((g.user_id = c.user_id)
                AND (g.week = c.week)
                AND (g.category_path <@ c.path)
                AND goal_type_equal (g.type, c.type))))
WINDOW w AS (PARTITION BY g.user_id, g.category_id, g.type ORDER BY g.week RANGE BETWEEN '21 days'::interval PRECEDING AND CURRENT ROW);

CREATE OR REPLACE VIEW "public"."goal_monthly" AS
SELECT
    g.user_id,
    (m.month)::date AS month,
    g.category_id,
    text2ltree (min(ltree2text (g.category_path))) AS category_path,
    g.type,
    (sum(((g.minutes / 7) * week_days_in_month (g.week, (m.month)::date))))::integer AS minutes
FROM (generate_series(((date_trunc('month'::text, (CURRENT_DATE - '1 year'::interval)))::date)::timestamp with time zone, ((CURRENT_DATE + '1 year'::interval)::date)::timestamp with time zone, '1 mon'::interval) m (month)
    LEFT JOIN goal_weekly g ON ((daterange(g.week, (g.week + 7), '[)'::text) <@ daterange((m.month)::date, (m.month + '1 mon'::interval)::date, '[)'::text))))
GROUP BY
    g.user_id,
    m.month,
    g.category_id,
    g.type;

CREATE OR REPLACE VIEW "public"."balance_monthly" AS
SELECT
    g.user_id,
    g.month,
    g.category_id,
    g.category_path,
    g.type,
    sum((g.minutes - COALESCE(i.minutes, (0)::bigint))) OVER w AS minutes,
    sum(i.pending_minutes) OVER w AS pending_minutes
FROM (goal_monthly g
    LEFT JOIN category_total_monthly i ON (((g.user_id = i.user_id)
                AND (g.month = i.month)
                AND (g.category_path <@ i.path)
                AND goal_type_equal (g.type, i.type))))
WINDOW w AS (PARTITION BY g.user_id, g.category_id, g.type ORDER BY g.month RANGE BETWEEN '21 days'::interval PRECEDING AND CURRENT ROW);

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

ALTER VIEW insight_monthly SET (security_invoker = TRUE);

ALTER VIEW category_total_weekly SET (security_invoker = TRUE);

ALTER VIEW category_total_monthly SET (security_invoker = TRUE);

ALTER VIEW goal_weekly SET (security_invoker = TRUE);

ALTER VIEW goal_monthly SET (security_invoker = TRUE);

ALTER VIEW balance_weekly SET (security_invoker = TRUE);

ALTER VIEW balance_monthly SET (security_invoker = TRUE);

ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW prep_monthly SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

