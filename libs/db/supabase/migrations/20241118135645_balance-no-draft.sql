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
    max(event_x.updated_at) AS updated_at
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
    max(session.updated_at) AS updated_at
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
    max(note.updated_at) AS updated_at
FROM
    note
WHERE ((note.draft = FALSE)
    AND (note.do_at IS NOT NULL)
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

ALTER VIEW note_x SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
-- ALTER VIEW insight_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
