CREATE OR REPLACE VIEW expenditure WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    day,
    activity_id,
    COALESCE((count(*) FILTER (WHERE response != 'declined'::event_response))::integer, 0) AS count,
    COALESCE((sum(minutes) FILTER (WHERE response != 'declined'::event_response))::integer, 0) AS minutes,
    COALESCE((count(*) FILTER (WHERE response = 'tentative'::event_response
            OR response IS NULL))::integer, 0) AS tentative_count,
    COALESCE((sum(minutes) FILTER (WHERE response = 'tentative'::event_response
            OR response IS NULL))::integer, 0) AS tentative_minutes,
    COALESCE((count(*) FILTER (WHERE response = 'declined'::event_response))::integer, 0) AS declined_count,
    COALESCE((sum(minutes) FILTER (WHERE response = 'declined'::event_response))::integer, 0) AS declined_minutes
FROM
    event_x
WHERE
    status != 'cancelled'
GROUP BY
    user_id,
    day,
    activity_id;

CREATE OR REPLACE VIEW time_expenditure WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    (lower(at) at time zone user_timezone ())::date AS day,
    activity_id,
    count(*)::integer AS count,
    sum((EXTRACT(EPOCH FROM planned) - EXTRACT(EPOCH FROM remaining)) / 60)::integer AS minutes
FROM
    time
GROUP BY
    user_id,
    day,
    activity_id;

CREATE OR REPLACE VIEW expenditure_weekly WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    COALESCE(e.user_id, t.user_id) AS user_id,
    week_from_date (COALESCE(e.day, t.day)) AS week,
    COALESCE(e.activity_id, t.activity_id) AS activity_id,
    SUM(COALESCE(e.count, 0) + COALESCE(t.count, 0)) AS count,
    SUM(COALESCE(e.minutes, 0) + COALESCE(t.minutes, 0)) AS minutes,
    SUM(COALESCE(e.tentative_count, 0)) AS tentative_count,
    SUM(COALESCE(e.tentative_minutes, 0)) AS tentative_minutes,
    SUM(COALESCE(e.declined_count, 0)) AS declined_count,
    SUM(COALESCE(e.declined_minutes, 0)) AS declined_minutes
FROM
    expenditure e
    FULL JOIN time_expenditure t ON e.user_id = t.user_id
        AND e.day = t.day
        AND e.activity_id = t.activity_id
GROUP BY
    COALESCE(e.user_id, t.user_id),
    week_from_date (COALESCE(e.day, t.day)),
    COALESCE(e.activity_id, t.activity_id);

CREATE OR REPLACE VIEW budget_weekly WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    COALESCE(b.user_id, e.user_id) AS user_id,
    COALESCE(b.week, e.week) AS week,
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

