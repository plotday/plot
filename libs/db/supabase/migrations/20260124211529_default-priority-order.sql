DROP TRIGGER IF EXISTS "upsert_user_priority" ON "public"."user_priority";

DROP VIEW IF EXISTS "public"."user_priority";

DROP VIEW IF EXISTS "public"."priority_settings_inherited";

ALTER TABLE "public"."priority_settings"
    ALTER COLUMN "order" DROP DEFAULT;

CREATE OR REPLACE VIEW "public"."priority_settings_inherited" AS
WITH inherited_sources AS (
    SELECT
        ps.user_id,
        p.id AS priority_id,
        (nlevel (p.path) - nlevel (parent.path)) AS distance,
        0 AS source_type,
        CASE WHEN ((nlevel (p.path) > nlevel (parent.path))
            AND (subpath (p.path, nlevel (parent.path)) <> ''::ltree)) THEN
            (ps.path || subpath (p.path, nlevel (parent.path)))
        ELSE
            ps.path
        END AS path,
        ps.pomodoro,
        ps.color
    FROM ((priority_settings ps
            JOIN priority parent ON (ps.priority_id = parent.id))
        JOIN priority p ON (p.path <@ parent.path))
    WHERE ((ps.path IS NOT NULL)
        OR (ps.pomodoro IS NOT NULL)
        OR (ps.color IS NOT NULL))
UNION ALL
SELECT
    pu.user_id,
    p.id AS priority_id,
    (nlevel (p.path) - nlevel (parent.path)) AS distance,
    1 AS source_type,
    NULL::ltree AS path,
    NULL::integer AS pomodoro,
    parent.color
FROM (((priority_user pu
            JOIN priority root ON (pu.priority_id = root.id))
        JOIN priority p ON (p.path <@ root.path))
    JOIN priority parent ON (p.path <@ parent.path))
WHERE (parent.color IS NOT NULL))
SELECT DISTINCT ON (user_id, priority_id)
    user_id,
    priority_id,
    path,
    pomodoro,
    color
FROM
    inherited_sources
ORDER BY
    user_id,
    priority_id,
    distance,
    source_type;

CREATE OR REPLACE VIEW "public"."user_priority" AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    ((pu.personal = TRUE)
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
    COALESCE(settings."order", ((EXTRACT(epoch FROM p.created_at) * (1000)::numeric))::double precision) AS "order",
    inherited_settings.pomodoro,
    inherited_settings.color,
    COALESCE(upu.unread, FALSE) AS unread
FROM (((((((priority_user pu
                            JOIN priority root ON (pu.priority_id = root.id))
                        JOIN priority_user pu_root ON (((pu.user_id = pu_root.user_id)
                                    AND (pu_root.personal = TRUE))))
                    JOIN priority user_root ON (pu_root.priority_id = user_root.id))
                JOIN priority p ON (root.path @> p.path))
            LEFT JOIN priority_settings settings ON (((settings.user_id = pu.user_id)
                        AND (p.id = settings.priority_id))))
        LEFT JOIN priority_settings_inherited inherited_settings ON (((inherited_settings.user_id = pu.user_id)
                    AND (p.id = inherited_settings.priority_id))))
    LEFT JOIN user_priority_unread upu ON (((upu.user_id = pu.user_id)
                AND (upu.priority_id = p.id))))
WHERE (pu.archived_at IS NULL);

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON public.user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_tag_change" SET ( security_invoker = TRUE);
ALTER VIEW public.priority_member SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
