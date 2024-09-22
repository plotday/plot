DROP TRIGGER IF EXISTS "insert_context_x" ON "public"."context_x";

DROP TRIGGER IF EXISTS "update_context_x" ON "public"."context_x";

ALTER TABLE "public"."session"
    DROP CONSTRAINT "session_check";

ALTER TABLE "public"."session"
    DROP CONSTRAINT "session_event_id_fkey";

ALTER TABLE "public"."session"
    DROP CONSTRAINT "session_paused_check";

ALTER TABLE "public"."session"
    DROP CONSTRAINT "session_pomodoro_length_check";

ALTER TABLE "public"."session"
    DROP CONSTRAINT "session_user_id_expr_at_excl";

DROP VIEW IF EXISTS "public"."context_x";

DROP VIEW IF EXISTS "public"."expenditure_weekly";

DROP VIEW IF EXISTS "public"."expenditure";

SELECT
    1;

-- drop index if exists "public"."session_user_id_expr_at_excl";
ALTER TABLE "public"."context_settings"
    ALTER COLUMN "pomodoro" SET DEFAULT (25 * 60);

ALTER TABLE "public"."session"
    DROP COLUMN "event_id";

ALTER TABLE "public"."session"
    DROP COLUMN "paused";

ALTER TABLE "public"."session"
    DROP COLUMN "pomodoro_length";

ALTER TABLE "public"."session"
    DROP COLUMN "pomodoro_start";

ALTER TABLE "public"."session"
    ADD COLUMN "pomodoro" smallint;

ALTER TABLE "public"."session"
    ADD COLUMN "pomodoro_remaining" smallint;

ALTER TABLE "public"."session"
    ADD COLUMN "priority" smallint NOT NULL DEFAULT 0;

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_pomodoro_check" CHECK (((pomodoro IS NULL) OR (pomodoro > 0))) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_pomodoro_check";

ALTER TABLE "public"."session"
    ADD CONSTRAINT "session_pomodoro_check1" CHECK (((pomodoro IS NULL) OR (pomodoro > 0))) NOT valid;

ALTER TABLE "public"."session" validate CONSTRAINT "session_pomodoro_check1";

CREATE OR REPLACE VIEW "public"."context_x" AS
SELECT
    c2.id,
    cu.user_id,
    c2.created_at,
    GREATEST (cs.modified_at, cu.modified_at, c2.modified_at) AS modified_at,
    c2.name,
    replace_parent_path (c1.path, c2.path, COALESCE(cu.path, c1.path)) AS path,
    COALESCE(cs."order", (((EXTRACT(epoch FROM CURRENT_TIMESTAMP) * (1000)::numeric))::double precision * (10)::double precision)) AS "order",
    COALESCE(cs.pomodoro, 25) AS pomodoro
FROM (((context_user cu
            JOIN context c1 ON (cu.context_id = c1.id))
        JOIN context c2 ON (c1.path @> c2.path))
    LEFT JOIN context_settings cs ON (((cs.user_id = cu.user_id)
                AND (c2.id = cs.context_id))));

CREATE OR REPLACE VIEW "public"."expenditure" AS
SELECT
    COALESCE(e.user_id, s.user_id) AS user_id,
    COALESCE(e.day, s.day) AS day,
    COALESCE(e.context_id, s.context_id) AS context_id,
    COALESCE((COALESCE(e.count, (0)::bigint) + COALESCE(s.count, (0)::bigint))) AS count,
    COALESCE((COALESCE(e.minutes, (0)::bigint) + COALESCE(s.minutes, 0))) AS minutes,
    COALESCE(e.tentative_count, (0)::bigint) AS tentative_count,
    COALESCE(e.tentative_minutes, (0)::bigint) AS tentative_minutes,
    COALESCE(e.declined_count, (0)::bigint) AS declined_count,
    COALESCE(e.declined_minutes, (0)::bigint) AS declined_minutes
FROM ((
        SELECT
            event_x.user_id,
            event_x.day,
            event_x.context_id,
            COALESCE(count(*) FILTER (WHERE (event_x.response <> 'declined'::event_response)), (0)::bigint) AS count,
            COALESCE(sum(event_x.minutes) FILTER (WHERE (event_x.response <> 'declined'::event_response)), (0)::bigint) AS minutes,
            COALESCE(count(*) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
                OR (event_x.response IS NULL))), (0)::bigint) AS tentative_count,
            COALESCE(sum(event_x.minutes) FILTER (WHERE ((event_x.response = 'tentative'::event_response)
                OR (event_x.response IS NULL))), (0)::bigint) AS tentative_minutes,
            COALESCE(count(*) FILTER (WHERE (event_x.response = 'declined'::event_response)), (0)::bigint) AS declined_count,
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
            count(*) AS count,
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
    sum(COALESCE(expenditure.count, (0)::bigint)) AS count,
    sum(expenditure.minutes) AS minutes,
    sum(expenditure.tentative_count) AS tentative_count,
    sum(expenditure.tentative_minutes) AS tentative_minutes,
    sum(expenditure.declined_count) AS declined_count,
    sum(expenditure.declined_minutes) AS declined_minutes
FROM
    expenditure
GROUP BY
    expenditure.user_id,
    (week_from_date (expenditure.day)),
    expenditure.context_id;

CREATE TRIGGER insert_context_x
    INSTEAD OF INSERT ON public.context_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_context_x_insert ();

CREATE TRIGGER update_context_x
    INSTEAD OF UPDATE ON public.context_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_context_x_update ();

ALTER VIEW note_x SET (security_invoker = TRUE);

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

-- ALTER VIEW insight_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_invitees" SET (security_invoker = TRUE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."context_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."waitlist_admin" SET (security_invoker = FALSE);

ALTER VIEW expenditure SET (security_invoker = TRUE);

ALTER VIEW expenditure_weekly SET (security_invoker = TRUE);

ALTER VIEW "public"."sync_admin" SET (security_invoker = FALSE);

