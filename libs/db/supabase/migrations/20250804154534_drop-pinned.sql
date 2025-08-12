DROP TRIGGER IF EXISTS "upsert_activity_x" ON "public"."activity_x";

DROP VIEW IF EXISTS "public"."activity_children";

DROP VIEW IF EXISTS "public"."activity_x";

DROP VIEW IF EXISTS "public"."balance";

DROP VIEW IF EXISTS "public"."balance_without_children";

DROP VIEW IF EXISTS "public"."priority_tags";

ALTER TABLE "public"."activity"
    DROP COLUMN "pinned";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."activity_x" AS
SELECT
    a.id,
    pu.user_id,
    a.created_at,
    GREATEST (a.updated_at, COALESCE(tags.updated_at, a.updated_at)) AS updated_at,
    CASE WHEN (COALESCE(tags.updated_at, a.updated_at) > a.updated_at) THEN
        tags.updated_by
    ELSE
        a.updated_by
    END AS updated_by,
    a.deleted_at,
    a.created_by,
    a.priority_id,
    a.path,
    a.draft,
    a.private,
    a.do_at,
    a.done_at,
    a.title,
    a.note,
    a.event_series,
    a."order",
    (COALESCE(a.done_at, (a.do_at)::timestamp with time zone, a.created_at))::date AS day,
    tags.tags
FROM (((priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id)
                        OR (p.path <@ (
                                SELECT
                                    priority.path
                                FROM
                                    priority
                            WHERE (priority.id = pu.priority_id))))))
        JOIN activity a ON (a.priority_id = p.id))
    LEFT JOIN activity_tags tags ON (tags.activity_id = a.id))
WHERE ((pu.deleted_at IS NULL)
    AND (p.deleted_at IS NULL));

CREATE OR REPLACE VIEW "public"."balance_without_children" AS
SELECT
    event_x.user_id,
    event_x.day,
    event_x.priority_id,
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
    event_x.priority_id,
    event_x.response
UNION ALL
SELECT
    session.user_id,
    ((lower(session.at) AT TIME ZONE user_timezone ()))::date AS day,
    session.priority_id,
    'session'::text AS type,
    count(*) AS count,
    (sum(EXTRACT(epoch FROM (upper(session.at) - lower(session.at)))))::integer AS seconds,
    max(session.updated_at) AS updated_at
FROM
    session
GROUP BY
    session.user_id,
    (((lower(session.at) AT TIME ZONE user_timezone ()))::date),
    session.priority_id
UNION ALL
SELECT
    priority_user.user_id,
    ((COALESCE(activity.done_at, (activity.do_at)::timestamp with time zone) AT TIME ZONE user_timezone ()))::date AS day,
    activity.priority_id,
    CASE WHEN (activity.done_at IS NULL) THEN
        'todo'::text
    ELSE
        'done'::text
    END AS type,
    count(*) AS count,
    0 AS seconds,
    max(activity.updated_at) AS updated_at
FROM (activity
    JOIN priority_user ON (priority_user.priority_id = activity.priority_id))
WHERE ((activity.draft = FALSE)
    AND ((activity.do_at IS NOT NULL)
        OR (activity.done_at IS NOT NULL)))
GROUP BY
    priority_user.user_id,
    (((COALESCE(activity.done_at, (activity.do_at)::timestamp with time zone) AT TIME ZONE user_timezone ()))::date),
    activity.priority_id,
    CASE WHEN (activity.done_at IS NULL) THEN
        'todo'::text
    ELSE
        'done'::text
    END;

CREATE OR REPLACE FUNCTION public.handle_activity_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _activity_id uuid;
BEGIN
    _activity_id := NEW.id;
    -- Insert or update the activity
    INSERT INTO activity (id, updated_by, deleted_at, priority_id, path, draft, private, do_at, done_at, "order", title, note, event_series)
        VALUES (NEW.id, NEW.updated_by, NEW.deleted_at, NEW.priority_id, NEW.path, NEW.draft, NEW.private, NEW.do_at, NEW.done_at, NEW.order, NEW.title, NEW.note, NEW.event_series)
    ON CONFLICT (id)
        DO UPDATE SET
            updated_by = NEW.updated_by,
            deleted_at = NEW.deleted_at,
            priority_id = NEW.priority_id,
            path = NEW.path,
            draft = NEW.draft,
            private = NEW.private,
            do_at = NEW.do_at,
            done_at = NEW.done_at,
            "order" = NEW.order,
            title = NEW.title,
            note = NEW.note,
            event_series = NEW.event_series
        RETURNING
            id INTO _activity_id;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE VIEW "public"."priority_tags" AS
SELECT
    a.priority_id,
    t.id AS tag_id,
    t.emoji,
    count(*) AS count,
    max(COALESCE(at.deleted_at, at.created_at)) AS latest_at
FROM ((activity_tag at
        JOIN tag t ON (at.tag_id = t.id))
    JOIN activity a ON (at.activity_id = a.id))
WHERE ((at.deleted_at IS NULL)
    AND (a.deleted_at IS NULL)
    AND (nlevel (a.path) = 1))
GROUP BY
    a.priority_id,
    t.id,
    t.emoji;

CREATE OR REPLACE VIEW "public"."activity_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (activity_x a
    JOIN activity c ON (c.path <@ a.path));

CREATE OR REPLACE VIEW "public"."balance" AS
SELECT
    b.user_id,
    b.day,
    NULL::uuid AS priority_id,
    b.type,
    sum(b.count) AS count,
    (sum(b.seconds))::integer AS seconds,
    max(b.updated_at) AS updated_at
FROM
    balance_without_children b
WHERE (b.priority_id IS NULL)
GROUP BY
    b.user_id,
    b.day,
    b.type
UNION ALL
SELECT
    b.user_id,
    b.day,
    b.priority_id,
    b.type,
    sum(b.count) AS count,
    (sum(b.seconds))::integer AS seconds,
    max(b.updated_at) AS updated_at
FROM (balance_without_children b
    JOIN priority_children ac ON (b.priority_id = ac.child_id))
WHERE (b.priority_id IS NOT NULL)
GROUP BY
    b.user_id,
    b.day,
    b.priority_id,
    b.type;

CREATE TRIGGER upsert_activity_x
    INSTEAD OF INSERT OR UPDATE ON public.activity_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_activity_x_upsert ();

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW "admin"."sync" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW public.calendar_x SET ( security_invoker = TRUE);
ALTER VIEW "admin"."user" SET ( security_invoker = FALSE);
ALTER VIEW balance_without_children SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."agent_x" SET ( security_invoker = TRUE);
