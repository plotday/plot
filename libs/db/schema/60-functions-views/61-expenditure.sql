CREATE VIEW expenditure WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    e."user_id",
    e."day",
    el."label_id",
    e.response,
    count(*)::integer AS event_count,
    sum(e.minutes)::integer AS minutes,
    -- exclude "initiated" label
    count(*) FILTER (WHERE e.initiated
        AND el.label_id != 24)::integer AS org_event_count,
    sum(e.minutes * e.invitee_count) FILTER (WHERE e.initiated
        AND el.label_id != 24)::integer AS org_minutes
FROM
    "public"."event_x" e
    JOIN "public"."event_label" el ON e."id" = el."event_id"
WHERE
    e."status" != 'cancelled'
GROUP BY
    e.user_id,
    e.day,
    el."label_id",
    e.response;

CREATE VIEW expenditure_monthly WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    date_trunc('month', "day")::date AS "month",
    label_id,
    response,
    sum(event_count) AS event_count,
    sum(minutes) AS minutes,
    sum(org_event_count) AS org_event_count,
    sum(org_minutes) AS org_minutes
FROM
    "public"."expenditure" e
GROUP BY
    user_id,
    "month",
    label_id,
    response;

-- Define a computed relation for PostgREST joins
-- https://postgrest.org/en/stable/references/api/resource_embedding.html#computed-relationships
CREATE OR REPLACE FUNCTION public.label (expenditure_monthly)
    RETURNS SETOF label ROWS 1
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        *
    FROM
        label
    WHERE
        id = $1.label_id
$function$;

CREATE VIEW expenditure_rolling WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    COALESCE(expenditure.user_id, expenditure_expiries.user_id) AS user_id,
    COALESCE(expenditure.day, expenditure_expiries.day) AS day,
    COALESCE(expenditure.label_id, expenditure_expiries.label_id) AS label_id,
    COALESCE(expenditure.response, expenditure_expiries.response) AS response,
    SUM(COALESCE(expenditure.event_count, 0)) OVER w AS event_count,
    SUM(COALESCE(expenditure.minutes, 0)) OVER w AS minutes,
    SUM(COALESCE(expenditure.org_event_count, 0)) OVER w AS org_event_count,
    SUM(COALESCE(expenditure.org_minutes, 0)) OVER w AS org_minutes
FROM
    expenditure
    FULL OUTER JOIN (
    SELECT
        user_id, (day + INTERVAL '28 days')::date AS day,
        label_id,
        response
    FROM
        expenditure) AS expenditure_expiries ON expenditure.user_id = expenditure_expiries.user_id
        AND expenditure.day = expenditure_expiries.day
        AND expenditure.label_id = expenditure_expiries.label_id
        AND expenditure.response = expenditure_expiries.response
WINDOW w AS (PARTITION BY COALESCE(expenditure.user_id, expenditure_expiries.user_id),
    COALESCE(expenditure.label_id, expenditure_expiries.label_id),
    COALESCE(expenditure.response, expenditure_expiries.response)
ORDER BY
    COALESCE(expenditure.day, expenditure_expiries.day)
    RANGE BETWEEN '27 days' PRECEDING AND CURRENT ROW)
ORDER BY
    day;

