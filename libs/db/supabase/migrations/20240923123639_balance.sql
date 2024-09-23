DROP VIEW IF EXISTS "public"."expenditure_weekly";

DROP VIEW IF EXISTS "public"."expenditure";

CREATE OR REPLACE VIEW "public"."expenditure" AS
SELECT
    COALESCE(e.user_id, s.user_id) AS user_id,
    COALESCE(e.day, s.day) AS day,
    COALESCE(e.context_id, s.context_id) AS context_id,
    COALESCE((COALESCE(e.events, (0)::bigint) + COALESCE(s.events, (0)::bigint))) AS events,
    COALESCE((COALESCE(e.minutes, (0)::bigint) + COALESCE(s.minutes, 0))) AS minutes,
    COALESCE(e.tentative_events, (0)::bigint) AS tentative_events,
    COALESCE(e.tentative_minutes, (0)::bigint) AS tentative_minutes,
    COALESCE(e.declined_events, (0)::bigint) AS declined_events,
    COALESCE(e.declined_minutes, (0)::bigint) AS declined_minutes
FROM ((
        SELECT
            event_x.user_id,
            event_x.day,
            event_x.context_id,
            COALESCE(count(*) FILTER (WHERE (event_x.response <> 'declined'::event_response)), (0)::bigint) AS events,
            COALESCE(sum(event_x.minutes) FILTER (WHERE (event_x.response <> 'declined'::event_response)), (0)::bigint) AS minutes,
            COALESCE(count(*) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
                OR (event_x.response IS NULL))), (0)::bigint) AS tentative_events,
            COALESCE(sum(event_x.minutes) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
                OR (event_x.response IS NULL))), (0)::bigint) AS tentative_minutes,
            COALESCE(count(*) FILTER (WHERE (event_x.response = 'declined'::event_response)), (0)::bigint) AS declined_events,
            COALESCE(sum(event_x.minutes) FILTER (WHERE (event_x.response = 'declined'::event_response)), (0)::bigint) AS declined_minutes
        FROM
            event_x
        WHERE ((event_x.status <> 'cancelled'::event_status)
            AND (event_x.response <> 'declined'::event_response)
            AND (event_x.all_day = FALSE))
    GROUP BY
        event_x.user_id,
        event_x.day,
        event_x.context_id) e
    FULL JOIN (
        SELECT
            session.user_id,
            ((lower(session.at) AT TIME ZONE user_timezone ()))::date AS day,
            session.context_id,
            count(*) AS events,
            (sum((EXTRACT(epoch FROM (upper(session.at) - lower(session.at))) / (60)::numeric)))::integer AS minutes
        FROM
            session
        GROUP BY
            session.user_id,
            (((lower(session.at) AT TIME ZONE user_timezone ()))::date),
            session.context_id) s ON (((e.user_id = s.user_id)
                AND (e.day = s.day)
                AND (e.context_id = s.context_id))));

CREATE OR REPLACE VIEW "public"."expenditure_weekly" AS
SELECT
    expenditure.user_id,
    week_from_date (expenditure.day) AS week,
    expenditure.context_id,
    sum(COALESCE(expenditure.events, (0)::bigint)) AS events,
    sum(expenditure.minutes) AS minutes,
    sum(expenditure.tentative_events) AS tentative_events,
    sum(expenditure.tentative_minutes) AS tentative_minutes,
    sum(expenditure.declined_events) AS declined_events,
    sum(expenditure.declined_minutes) AS declined_minutes
FROM
    expenditure
GROUP BY
    expenditure.user_id,
    (week_from_date (expenditure.day)),
    expenditure.context_id;

ALTER VIEW note_x SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
-- ALTER VIEW insight_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."context_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW expenditure SET ( security_invoker = TRUE);
ALTER VIEW expenditure_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
