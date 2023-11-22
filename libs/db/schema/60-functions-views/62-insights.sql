CREATE OR REPLACE VIEW insight WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    day,
    text2ltree (min(ltree2text (category_path))) AS category_path,
    type,
    response,
    nv.name,
    value,
    count(*)::integer AS count,
    sum(minutes)::integer AS minutes
FROM
    event_x e
    CROSS JOIN LATERAL (
        VALUES ('Total', NULL),
            ('Length', rounded_length::text),
            ('Size', size),
            ('Organizer', CASE WHEN initiated THEN
                    'You'
                ELSE
                    organizer_email
                END),
            ('External', CASE WHEN internal = 'internal' THEN
                    'Interal'
                WHEN internal = 'external' THEN
                    'External'
                ELSE
                    NULL
                END),
            ('Recurring', CASE WHEN recurring THEN
                    'Recurring'
                ELSE
                    'Ad hoc'
                END),
            ('Notice', CASE WHEN notice < 12 THEN
                    '< 12 hours'
                WHEN notice < 24 THEN
                    '< 24 hours'
                WHEN notice < 24 * 7 THEN
                    '< week'
                ELSE
                    '> week'
                END)) AS nv (name, value)
WHERE
    status != 'cancelled'
GROUP BY
    user_id,
    day,
    category_path,
    type,
    response,
    nv.name,
    value;

CREATE OR REPLACE FUNCTION week_from_date (d date)
    RETURNS daterange
    AS $$
    SELECT
        CASE WHEN d IS NULL THEN
            NULL
        ELSE
            daterange(date_bin ('7 days', d, '2023-1-1'::date)::date, date_bin ('7 days', d, '2023-1-1'::date)::date + 7, '[)'::text)
        END
$$
LANGUAGE sql
STABLE;

-- All categories, but not necessarily all weeks
CREATE OR REPLACE VIEW insight_weekly WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    c.user_id,
    c.path,
    week_from_date (i.day) AS week,
    i.type,
    i.name,
    i.value,
    COALESCE(SUM(i.count) FILTER (WHERE i.response = 'accepted'), 0) AS count,
    COALESCE(SUM(i.minutes) FILTER (WHERE i.response = 'accepted'), 0) AS minutes,
    COALESCE(SUM(i.count) FILTER (WHERE i.response IS NULL), 0) AS pending_count,
    COALESCE(SUM(i.minutes) FILTER (WHERE i.response IS NULL), 0) AS pending_minutes
FROM
    category c
    LEFT JOIN insight i ON c.path = i.category_path
GROUP BY
    c.user_id,
    c.path,
    week_from_date (i.day),
    i.type,
    i.name,
    i.value;

