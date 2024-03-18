DROP VIEW IF EXISTS "public"."budget_weekly";

DROP VIEW IF EXISTS "public"."expenditure_weekly";

DROP VIEW IF EXISTS "public"."expenditure";

CREATE OR REPLACE VIEW "public"."time_expenditure" AS
SELECT
    "time".user_id,
    ((lower("time".at) AT TIME ZONE user_timezone ()))::date AS day,
    "time".activity_id,
    (count(*))::integer AS count,
    (sum(((EXTRACT(epoch FROM "time".planned) - EXTRACT(epoch FROM "time".remaining)) / (60)::numeric)))::integer AS minutes
FROM
    "time"
GROUP BY
    "time".user_id,
    (((lower("time".at) AT TIME ZONE user_timezone ()))::date),
    "time".activity_id;

CREATE OR REPLACE VIEW "public"."expenditure" AS
SELECT
    event_x.user_id,
    event_x.day,
    event_x.activity_id,
    COALESCE((count(*) FILTER (WHERE (event_x.response <> 'declined'::event_response)))::integer, 0) AS count,
    COALESCE((sum(event_x.minutes) FILTER (WHERE (event_x.response <> 'declined'::event_response)))::integer, 0) AS minutes,
    COALESCE((count(*) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
        OR (event_x.response IS NULL))))::integer, 0) AS tentative_count,
    COALESCE((sum(event_x.minutes) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
        OR (event_x.response IS NULL))))::integer, 0) AS tentative_minutes,
    COALESCE((count(*) FILTER (WHERE (event_x.response = 'declined'::event_response)))::integer, 0) AS declined_count,
    COALESCE((sum(event_x.minutes) FILTER (WHERE (event_x.response = 'declined'::event_response)))::integer, 0) AS declined_minutes
FROM
    event_x
WHERE (event_x.status <> 'cancelled'::event_status)
GROUP BY
    event_x.user_id,
    event_x.day,
    event_x.activity_id;

CREATE OR REPLACE VIEW "public"."expenditure_weekly" AS
SELECT
    COALESCE(e.user_id, t.user_id) AS user_id,
    week_from_date (COALESCE(e.day, t.day)) AS week,
    COALESCE(e.activity_id, t.activity_id) AS activity_id,
    sum((COALESCE(e.count, 0) + COALESCE(t.count, 0))) AS count,
    sum((COALESCE(e.minutes, 0) + COALESCE(t.minutes, 0))) AS minutes,
    sum(COALESCE(e.tentative_count, 0)) AS tentative_count,
    sum(COALESCE(e.tentative_minutes, 0)) AS tentative_minutes,
    sum(COALESCE(e.declined_count, 0)) AS declined_count,
    sum(COALESCE(e.declined_minutes, 0)) AS declined_minutes
FROM (expenditure e
    FULL JOIN time_expenditure t ON (((e.user_id = t.user_id)
                AND (e.day = t.day)
                AND (e.activity_id = t.activity_id))))
GROUP BY
    COALESCE(e.user_id, t.user_id),
    (week_from_date (COALESCE(e.day, t.day))),
    COALESCE(e.activity_id, t.activity_id);

CREATE OR REPLACE VIEW "public"."budget_weekly" AS
SELECT
    COALESCE(b.user_id, e.user_id) AS user_id,
    COALESCE(b.week, e.week) AS week,
    COALESCE(b.activity_id, e.activity_id) AS activity_id,
    b."order",
    b.budget,
    COALESCE(e.count, (0)::bigint) AS count,
    COALESCE(e.minutes, (0)::bigint) AS minutes,
    COALESCE(e.tentative_count, (0)::bigint) AS tentative_count,
    COALESCE(e.tentative_minutes, (0)::bigint) AS tentative_minutes,
    COALESCE(e.declined_count, (0)::bigint) AS declined_count,
    COALESCE(e.declined_minutes, (0)::bigint) AS declined_minutes
FROM (budget b
    FULL JOIN expenditure_weekly e ON (((b.user_id = e.user_id)
                AND (b.week = e.week)
                AND (b.activity_id = e.activity_id))))
WHERE ((b.week IS NOT NULL)
    OR (e.week IS NOT NULL));

ALTER VIEW expenditure SET ( security_invoker = TRUE);
ALTER VIEW time_expenditure SET ( security_invoker = TRUE);
ALTER VIEW expenditure_weekly SET ( security_invoker = TRUE);
ALTER VIEW budget_weekly SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW insight_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
