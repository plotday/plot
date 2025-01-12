CREATE OR REPLACE VIEW insight WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    user_id,
    day,
    text2ltree (min(ltree2text (priority_path))) AS priority_path,
    type,
    response,
    nv.name,
    value,
    count(*)::integer AS count,
    sum(seconds)::integer AS seconds
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
            ('External', CASE WHEN external = TRUE THEN
                    'External'
                ELSE
                    'Internal'
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
    priority_path,
    type,
    response,
    nv.name,
    value;

