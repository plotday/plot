CREATE OR REPLACE VIEW expenditure WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    COALESCE(e.user_id, s.user_id) AS user_id,
    COALESCE(e.day, s.day) AS day,
    COALESCE(e.context_id, s.context_id) AS context_id,
    COALESCE(COALESCE(e.events, 0) + COALESCE(s.events, 0)) AS events,
    COALESCE(COALESCE(e.minutes, 0) + COALESCE(s.minutes, 0)) AS minutes,
    COALESCE(e.tentative_events, 0) AS tentative_events,
    COALESCE(e.tentative_minutes, 0) AS tentative_minutes,
    COALESCE(e.declined_events, 0) AS declined_events,
    COALESCE(e.declined_minutes, 0) AS declined_minutes
FROM (
    SELECT
        user_id,
        day,
        context_id,
        COALESCE(count(*) FILTER (WHERE response != 'declined'), 0) AS events,
        COALESCE(sum(minutes) FILTER (WHERE response != 'declined'), 0) AS minutes,
        COALESCE(count(*) FILTER (WHERE response = 'tentative'
                OR response IS NULL), 0) AS tentative_events,
        COALESCE(sum(minutes) FILTER (WHERE response = 'tentative'
                OR response IS NULL), 0) AS tentative_minutes,
        COALESCE(count(*) FILTER (WHERE response = 'declined'), 0) AS declined_events,
        COALESCE(sum(minutes) FILTER (WHERE response = 'declined'), 0) AS declined_minutes
    FROM
        event_x
    WHERE
        status != 'cancelled'
        AND response != 'declined'
        AND all_day = FALSE
    GROUP BY
        user_id,
        day,
        context_id) AS e
    FULL JOIN (
        SELECT
            user_id,
            (lower(at) at time zone user_timezone ())::date AS day,
            context_id,
            count(*) AS events,
            sum(EXTRACT(epoch FROM upper(at) - lower(at)) / 60)::integer AS minutes
        FROM
            session
        GROUP BY
            user_id,
            day,
            context_id) AS s ON e.user_id = s.user_id
    AND e.day = s.day
    AND e.context_id = s.context_id;

CREATE OR REPLACE VIEW expenditure_weekly WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    week_from_date (day) AS week,
    context_id,
    SUM(COALESCE(events, 0)) AS events,
    SUM(minutes) AS minutes,
    SUM(tentative_events) AS tentative_events,
    SUM(tentative_minutes) AS tentative_minutes,
    SUM(declined_events) AS declined_events,
    SUM(declined_minutes) AS declined_minutes
FROM
    expenditure
GROUP BY
    user_id,
    week_from_date (day),
    context_id;

