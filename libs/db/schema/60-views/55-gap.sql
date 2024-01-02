CREATE OR REPLACE FUNCTION work_day_start ()
    RETURNS time
    AS $$
    SELECT
        '09:00'::time
$$
LANGUAGE sql
IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION work_day_end ()
    RETURNS time
    AS $$
    SELECT
        '17:00'::time
$$
LANGUAGE sql
IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE VIEW gap WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    day,
    at * tstzrange((day + work_day_start ()) AT TIME ZONE user_timezone (), (day + work_day_end ()) AT TIME ZONE user_timezone (), '[]') AS at,
    extract_minutes (at * tstzrange((day + work_day_start ()) AT TIME ZONE user_timezone (), (day + work_day_end ()) AT TIME ZONE user_timezone (), '[]')) AS minutes
FROM (
    SELECT
        user_id,
        day,
        CASE WHEN EXTRACT(isodow FROM day) <= 5
            AND MAX(UPPER(at)) OVER start_window < LOWER(at) THEN
            tstzrange(MAX(UPPER(at)) OVER start_window, LOWER(at), '[)')
        ELSE
            NULL
        END AS at
    FROM (
        SELECT
            user_id,
            day,
            at
        FROM
            event_x
        WHERE
            type = 'meeting'
            AND status != 'cancelled'
            AND response = 'accepted'
        UNION (
            -- insert zero-length events at midnight to ensure gaps don't span days
            SELECT DISTINCT
                auth.uid () AS id,
                day,
                tstzrange((day + interval '1 day') AT TIME ZONE user_timezone (), (day + interval '1 day') AT TIME ZONE user_timezone (), '[]') AS at
            FROM (
                SELECT
                    generate_series(min(lower(at))::date, max(upper(at))::date, '1 day')::date AS day
                FROM
                    event) AS days)) AS e
WINDOW start_window AS (PARTITION BY user_id ORDER BY LOWER(at),
    UPPER(at)
    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)) AS gap
WHERE
    at IS NOT NULL;

CREATE OR REPLACE VIEW gap_monthly WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    date_trunc('month', "day")::date AS "month",
    SUM(minutes) AS total,
    SUM(minutes) FILTER (WHERE minutes >= 60) AS focus
FROM
    gap
GROUP BY
    user_id,
    "month";

CREATE OR REPLACE VIEW gap_daily WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    day,
    SUM(minutes) AS total,
    SUM(minutes) FILTER (WHERE minutes >= 60) AS focus
FROM
    gap
GROUP BY
    user_id,
    day;

