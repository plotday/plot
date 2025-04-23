CREATE OR REPLACE VIEW balance_without_children WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    day,
    priority_id,
    CASE WHEN response IS NULL THEN
        'tentative'
    ELSE
        response::text
    END AS type,
    COUNT(*) AS "count",
    SUM(seconds) AS "seconds",
    MAX(updated_at) AS updated_at
FROM
    event_x
WHERE
    status != 'cancelled'
    AND all_day = FALSE
GROUP BY
    user_id,
    day,
    priority_id,
    response
UNION ALL
SELECT
    user_id,
    (lower(at) at time zone user_timezone ())::date AS day,
    priority_id,
    'session' AS type,
    count(*) AS "count",
    sum(EXTRACT(epoch FROM upper(at) - lower(at)))::integer AS seconds,
    MAX(updated_at) AS updated_at
FROM
    session
GROUP BY
    user_id,
    day,
    priority_id
UNION ALL
SELECT
    user_id,
    (COALESCE(done_at, do_at) at time zone user_timezone ())::date AS day,
    priority_id,
    CASE WHEN done_at IS NULL THEN
        'todo'
    ELSE
        'done'
    END AS type,
    COUNT(*) AS "count",
    0 AS "seconds",
    MAX(priority.updated_at) AS updated_at
FROM
    "public"."priority"
    INNER JOIN "public"."priority_user" ON priority_user.priority_id = priority.id
WHERE
    draft = FALSE
    AND do_at IS NOT NULL
    AND done_at IS NULL
GROUP BY
    user_id,
    day,
    priority_id,
    type;

CREATE OR REPLACE VIEW balance WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    day,
    NULL AS priority_id,
    type,
    SUM(b.count) AS "count",
    SUM(b.seconds)::integer AS "seconds",
    MAX(b.updated_at) AS updated_at
FROM
    balance_without_children b
WHERE
    b.priority_id IS NULL
GROUP BY
    user_id,
    day,
    type
UNION ALL
SELECT
    user_id,
    day,
    priority_id,
    type,
    SUM(b.count) AS "count",
    SUM(b.seconds)::integer AS "seconds",
    MAX(b.updated_at) AS updated_at
FROM
    balance_without_children b
    JOIN priority_children ac ON b.priority_id = ac.child_id
WHERE
    b.priority_id IS NOT NULL
GROUP BY
    user_id,
    day,
    priority_id,
    type;

