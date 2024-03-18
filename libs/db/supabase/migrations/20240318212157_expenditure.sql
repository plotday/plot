CREATE OR REPLACE VIEW "public"."expenditure" AS
SELECT
    e.user_id,
    e.day,
    e.activity_path,
    min(e.activity_id) AS activity_id,
    COALESCE((count(*) FILTER (WHERE (e.response <> 'declined'::event_response)))::integer, 0) AS count,
    COALESCE((sum(e.minutes) FILTER (WHERE (e.response <> 'declined'::event_response)))::integer, 0) AS minutes,
    COALESCE((count(*) FILTER (WHERE ((e.response = 'tentative'::event_response)
        OR (e.response IS NULL))))::integer, 0) AS tentative_count,
    COALESCE((sum(e.minutes) FILTER (WHERE ((e.response = 'tentative'::event_response)
        OR (e.response IS NULL))))::integer, 0) AS tentative_minutes,
    COALESCE((count(*) FILTER (WHERE (e.response = 'declined'::event_response)))::integer, 0) AS declined_count,
    COALESCE((sum(e.minutes) FILTER (WHERE (e.response = 'declined'::event_response)))::integer, 0) AS declined_minutes
FROM
    event_x e
WHERE (e.status <> 'cancelled'::event_status)
GROUP BY
    e.user_id,
    e.day,
    e.activity_path,
    e.activity_id;

CREATE OR REPLACE VIEW "public"."expenditure_weekly" AS
SELECT
    expenditure.user_id,
    week_from_date (expenditure.day) AS week,
    expenditure.activity_path,
    min(expenditure.activity_id) AS activity_id,
    sum(expenditure.count) AS count,
    sum(expenditure.minutes) AS minutes,
    sum(expenditure.tentative_count) AS tentative_count,
    sum(expenditure.tentative_minutes) AS tentative_minutes,
    sum(expenditure.declined_count) AS declined_count,
    sum(expenditure.declined_minutes) AS declined_minutes
FROM
    expenditure
GROUP BY
    expenditure.user_id,
    expenditure.activity_path,
    (week_from_date (expenditure.day));

CREATE OR REPLACE VIEW "public"."budget_weekly" AS
SELECT
    COALESCE(b.user_id, e.user_id) AS user_id,
    COALESCE(b.week, e.week) AS week,
    e.activity_path,
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
