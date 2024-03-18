CREATE OR REPLACE VIEW expenditure WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    day,
    activity_path,
    min(activity_id) AS activity_id,
    COALESCE((count(*) FILTER (WHERE response != 'declined'::event_response))::integer, 0) AS count,
    COALESCE((sum(minutes) FILTER (WHERE response != 'declined'::event_response))::integer, 0) AS minutes,
    COALESCE((count(*) FILTER (WHERE response = 'tentative'::event_response
            OR response IS NULL))::integer, 0) AS tentative_count,
    COALESCE((sum(minutes) FILTER (WHERE response = 'tentative'::event_response
            OR response IS NULL))::integer, 0) AS tentative_minutes,
    COALESCE((count(*) FILTER (WHERE response = 'declined'::event_response))::integer, 0) AS declined_count,
    COALESCE((sum(minutes) FILTER (WHERE response = 'declined'::event_response))::integer, 0) AS declined_minutes
FROM
    event_x e
WHERE
    status != 'cancelled'
GROUP BY
    user_id,
    day,
    activity_path,
    activity_id;

CREATE OR REPLACE VIEW expenditure_weekly WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    week_from_date (day) AS week,
    activity_path,
    MIN(activity_id) AS activity_id,
    SUM(count) AS count,
    SUM(minutes) AS minutes,
    SUM(tentative_count) AS tentative_count,
    SUM(tentative_minutes) AS tentative_minutes,
    SUM(declined_count) AS declined_count,
    SUM(declined_minutes) AS declined_minutes
FROM
    expenditure
GROUP BY
    user_id,
    activity_path,
    week_from_date (day);

CREATE OR REPLACE VIEW budget_weekly WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    COALESCE(b.user_id, e.user_id) AS user_id,
    COALESCE(b.week, e.week) AS week,
    e.activity_path,
    COALESCE(b.activity_id, e.activity_id) AS activity_id,
    b.order,
    b.budget,
    COALESCE(e.count, 0) AS count,
    COALESCE(e.minutes, 0) AS minutes,
    COALESCE(e.tentative_count, 0) AS tentative_count,
    COALESCE(e.tentative_minutes, 0) AS tentative_minutes,
    COALESCE(e.declined_count, 0) AS declined_count,
    COALESCE(e.declined_minutes, 0) AS declined_minutes
FROM
    budget b
    FULL JOIN expenditure_weekly e ON b.user_id = e.user_id
        AND b.week = e.week
        AND b.activity_id = e.activity_id
WHERE
    b.week IS NOT NULL
    OR e.week IS NOT NULL;

