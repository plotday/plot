CREATE OR REPLACE VIEW prep_monthly WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    date_trunc('month', "day")::date AS "month",
    COUNT(*) FILTER (WHERE (LOWER(at) < CURRENT_TIMESTAMP)) AS past_count,
COUNT(*) FILTER (WHERE (LOWER(at) < CURRENT_TIMESTAMP
    AND ready < LOWER(at))) AS past_ready_count,
COUNT(*) FILTER (WHERE (LOWER(at) < CURRENT_TIMESTAMP
    AND reviewed IS NOT NULL)) AS past_reviewed_count,
ROUND(AVG(EXTRACT(epoch FROM (COALESCE(reviewed, CURRENT_TIMESTAMP) - LOWER(at)))) FILTER (WHERE (LOWER(at) < CURRENT_TIMESTAMP)) / 60) AS review_time
FROM
    event_x e
WHERE
    type = 'meeting'
GROUP BY
    user_id,
    "month";

