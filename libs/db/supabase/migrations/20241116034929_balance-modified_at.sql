DROP VIEW IF EXISTS "public"."balance";

CREATE OR REPLACE VIEW "public"."balance" AS
SELECT
    event_x.user_id,
    event_x.day,
    event_x.activity_id,
    CASE WHEN (event_x.response IS NULL) THEN
        'tentative'::text
    ELSE
        (event_x.response)::text
    END AS type,
    count(*) AS count,
    sum(event_x.seconds) AS seconds,
    max(event_x.modified_at) AS modified_at
FROM
    event_x
WHERE ((event_x.status <> 'cancelled'::event_status)
    AND (event_x.all_day = FALSE))
GROUP BY
    event_x.user_id,
    event_x.day,
    event_x.activity_id,
    event_x.response
UNION ALL
SELECT
    session.user_id,
    ((lower(session.at) AT TIME ZONE user_timezone ()))::date AS day,
    session.activity_id,
    'session'::text AS type,
    count(*) AS count,
    (sum((EXTRACT(epoch FROM (upper(session.at) - lower(session.at))) / (60)::numeric)))::integer AS seconds,
    max(session.modified_at) AS modified_at
FROM
    session
GROUP BY
    session.user_id,
    (((lower(session.at) AT TIME ZONE user_timezone ()))::date),
    session.activity_id
UNION ALL
SELECT
    note.user_id,
    ((note.do_at AT TIME ZONE user_timezone ()))::date AS day,
    note.activity_id,
    CASE WHEN (note.do_at <= now()) THEN
        'do_now'::text
    ELSE
        'do_later'::text
    END AS type,
    count(*) AS count,
    0 AS seconds,
    max(note.modified_at) AS modified_at
FROM
    note
WHERE ((note.do_at IS NOT NULL)
    AND (note.done_at IS NULL))
GROUP BY
    note.user_id,
    (((note.do_at AT TIME ZONE user_timezone ()))::date),
    note.activity_id,
    CASE WHEN (note.do_at <= now()) THEN
        'do_now'::text
    ELSE
        'do_later'::text
    END;

ALTER VIEW balance SET (security_invoker = TRUE);

