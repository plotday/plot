DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

DROP VIEW IF EXISTS "public"."activity_children";

DROP VIEW IF EXISTS "public"."priority_tags";

DROP VIEW IF EXISTS "public"."user_activity_exception";

DROP VIEW IF EXISTS "public"."user_activity_tags";

DROP VIEW IF EXISTS "public"."user_activity";

DROP VIEW IF EXISTS "public"."user_activity_unread";

DROP VIEW IF EXISTS "public"."user_priority";

ALTER TABLE "public"."activity"
    ADD COLUMN "embedding" halfvec (384);

CREATE INDEX ON activity USING hnsw (embedding halfvec_cosine_ops);

CREATE OR REPLACE VIEW "public"."activity_children" AS
SELECT
    a.id,
    c.id AS child_id
FROM (activity a
    JOIN activity c ON (c.path <@ a.path));

CREATE OR REPLACE VIEW "public"."priority_tags" AS
SELECT
    a.priority_id,
    at.tag_id,
    count(*) AS count,
    max(COALESCE(at.deleted_at, at.updated_at)) AS updated_at
FROM (activity_tag at
    JOIN activity a ON (at.activity_id = a.id))
WHERE ((at.deleted_at IS NULL)
    AND (a.deleted_at IS NULL)
    AND (nlevel (a.path) = 1))
GROUP BY
    a.priority_id,
    at.tag_id;

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, COALESCE(activity_max.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), COALESCE(ar_max.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST (pu.deleted_at, p.deleted_at) AS deleted_at,
    p.created_by,
    p.updated_by,
    (root.root
        AND (p.id = root.id)) AS root,
    p.title,
    CASE WHEN (inherited_settings.path IS NOT NULL) THEN
        inherited_settings.path
    WHEN (user_root.path @> p.path) THEN
        p.path
    ELSE
        (user_root.path || p.path)
    END AS path,
    settings.top_order,
    inherited_settings.pomodoro,
    inherited_settings.color,
    COALESCE(unread.unread, FALSE) AS unread
FROM (((((((((priority_user pu
                                LEFT JOIN contact c ON (c.user_id = pu.user_id))
                            JOIN priority root ON (pu.priority_id = root.id))
                        JOIN priority user_root ON (((pu.user_id = user_root.created_by)
                                    AND user_root.root)))
                    JOIN priority p ON (root.path @> p.path))
                LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                            AND (p.id = settings.priority_id))))
            LEFT JOIN priority_settings_inherited inherited_settings ON (((inherited_settings.user_id = pu.user_id)
                        AND (p.id = inherited_settings.priority_id))))
        LEFT JOIN LATERAL (
            SELECT
                max(a.updated_at) AS updated_at
            FROM (activity a
                JOIN priority ap ON (ap.id = a.priority_id))
        WHERE ((ap.path <@ p.path)
            AND (a.deleted_at IS NULL))) activity_max ON (TRUE))
    LEFT JOIN LATERAL (
        SELECT
            max(ar.updated_at) AS updated_at
        FROM
            activity_read ar
        WHERE ((ar.user_id = pu.user_id)
            AND (ar.activity_path <@ p.path))) ar_max ON (TRUE))
    LEFT JOIN LATERAL (
        SELECT
            TRUE AS unread
        FROM ((activity a
                JOIN priority ap ON (ap.id = a.priority_id))
            LEFT JOIN activity_read ar ON (((ar.user_id = pu.user_id)
                        AND (ar.activity_path = subpath (a.path, 0, 1)))))
    WHERE ((ap.path <@ p.path)
        AND (a.deleted_at IS NULL)
        AND (a.author_id <> c.id)
        AND ((ar.read_at IS NULL)
            OR (a.created_at > ar.read_at)))
LIMIT 1) unread ON (TRUE))
WHERE (pu.deleted_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_activity_unread" AS
SELECT
    up.user_id,
    a.id AS activity_id,
    (unread.updated_at IS NOT NULL) AS unread,
    COALESCE(ar.updated_at, unread.updated_at) AS updated_at
FROM ((((user_priority up
                JOIN contact c ON (c.user_id = up.user_id))
            JOIN activity a ON (a.priority_id = up.id))
        LEFT JOIN activity_read ar ON (((ar.user_id = up.user_id)
                    AND (ar.activity_path = subpath (a.path, 0, 1)))))
    LEFT JOIN LATERAL (
        SELECT
            max(a2.updated_at) AS updated_at
        FROM
            activity a2
        WHERE ((a2.deleted_at IS NULL)
            AND (a2.path <@ a.path)
            AND (a2.author_id <> c.id)
            AND ((ar.read_at IS NULL)
                OR (a2.created_at > ar.read_at)))) unread ON (TRUE))
WHERE ((up.deleted_at IS NULL)
    AND (nlevel (a.path) = 1));

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    up.user_id,
    a.id,
    a.created_at,
    COALESCE(uau.updated_at, a.updated_at) AS updated_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    a.deleted_at,
    a.priority_id,
    p.path AS priority_path,
    a.type,
    a.path,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.note,
    a.links,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.recurrence_dates,
    a.meta,
    a.mentions,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(a.created_at, a.created_at, '[]'::text)
    END AS range_at,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a.at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a."on" IS NOT NULL) THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on,
    COALESCE(uau.unread, FALSE) AS unread
FROM (((activity a
            JOIN priority p ON (p.id = a.priority_id))
        JOIN user_priority up ON (a.priority_id = up.id))
    LEFT JOIN user_activity_unread uau ON (((uau.user_id = up.user_id)
                AND (uau.activity_id = a.id))))
WHERE (up.deleted_at IS NULL);

CREATE OR REPLACE VIEW "public"."user_activity_exception" AS
SELECT
    ua.user_id,
    ua.id,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae.at
    ELSE
        NULL::tstzrange
    END AS at,
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae."on"
    ELSE
        NULL::daterange
    END AS "on",
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae.title
    ELSE
        NULL::text
    END AS title,
    CASE WHEN (ae.deleted_at IS NULL) THEN
        ae.note
    ELSE
        NULL::text
    END AS note
FROM (activity_exception ae
    JOIN user_activity ua ON (ua.id = ae.activity_id));

CREATE OR REPLACE VIEW "public"."user_activity_tags" AS
SELECT
    ua.user_id,
    ua.id,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
FROM (activity_tags at
    JOIN user_activity ua ON (ua.id = at.activity_id));

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_agent" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

