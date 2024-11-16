CREATE OR REPLACE VIEW balance WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    day,
    activity_id,
    CASE WHEN response IS NULL THEN
        'tentative'
    ELSE
        response::text
    END AS type,
    COUNT(*) AS "count",
    SUM(seconds) AS "seconds",
    MAX(modified_at) AS modified_at
FROM
    event_x
WHERE
    status != 'cancelled'
    AND all_day = FALSE
GROUP BY
    user_id,
    day,
    activity_id,
    response
UNION ALL
SELECT
    user_id,
    (lower(at) at time zone user_timezone ())::date AS day,
    activity_id,
    'session' AS type,
    count(*) AS "count",
    sum(EXTRACT(epoch FROM upper(at) - lower(at)) / 60)::integer AS seconds,
    MAX(modified_at) AS modified_at
FROM
    session
GROUP BY
    user_id,
    day,
    activity_id
UNION ALL
SELECT
    user_id,
    (do_at at time zone user_timezone ())::date AS day,
    activity_id,
    CASE WHEN do_at <= NOW() THEN
        'do_now'
    ELSE
        'do_later'
    END AS type,
    COUNT(*) AS "count",
    0 AS "seconds",
    MAX(modified_at) AS modified_at
FROM
    "public"."note"
WHERE
    do_at IS NOT NULL
    AND done_at IS NULL
GROUP BY
    user_id,
    day,
    activity_id,
    type;

