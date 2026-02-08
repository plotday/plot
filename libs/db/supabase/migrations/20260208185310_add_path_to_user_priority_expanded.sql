SET ROLE "postgres";
SET check_function_bodies = false;

-- Update can_access_priority(uuid) to bypass user_priority_expanded for RLS performance
CREATE OR REPLACE FUNCTION public.can_access_priority(_priority_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority_user pu
                JOIN priority pp ON pu.priority_id = pp.id
                JOIN priority p ON p.path <@ pp.path
            WHERE
                pu.user_id = (
                    SELECT
                        auth.uid ())
                    AND pu.archived_at IS NULL
                    AND p.id = _priority_id);
$function$;

-- Drop user_priority_expanded CASCADE to allow adding the path column.
-- This will also drop all dependent views.
DROP VIEW IF EXISTS public.user_priority_expanded CASCADE;

-- Recreate user_priority_expanded with path column
CREATE OR REPLACE VIEW "public"."user_priority_expanded" WITH ( security_invoker = TRUE)
AS
WITH base AS (
    SELECT
        pu.user_id,
        c.child_id AS priority_id,
        MIN(pu.created_at) AS joined_at,
        LEAST (MIN(pu.archived_at), MIN(c.archived_at)) AS archived_at
    FROM
        priority_user pu
        JOIN priority_child c ON pu.priority_id = c.priority_id
    GROUP BY
        pu.user_id,
        c.child_id
)
SELECT
    b.user_id,
    b.priority_id,
    b.joined_at,
    b.archived_at,
    CASE
        WHEN inherited_settings.path IS NOT NULL THEN
            inherited_settings.path
        WHEN user_root.path @> p.path THEN
            p.path
        WHEN parent_inherited_settings.path IS NOT NULL THEN
            parent_inherited_settings.path || text(subpath (p.path, nlevel (p.path) - 1, 1))::ltree
        ELSE
            user_root.path || p.path
    END AS path
FROM
    base b
    LEFT JOIN priority p ON p.id = b.priority_id
    LEFT JOIN priority_user pu_root ON b.user_id = pu_root.user_id
        AND pu_root.personal = TRUE
    LEFT JOIN priority user_root ON pu_root.priority_id = user_root.id
    LEFT JOIN priority_settings_inherited inherited_settings ON inherited_settings.user_id = b.user_id
        AND inherited_settings.priority_id = b.priority_id
    LEFT JOIN priority parent_p ON nlevel (p.path) > 1
        AND parent_p.path = subpath (p.path, 0, nlevel (p.path) - 1)
    LEFT JOIN priority_settings_inherited parent_inherited_settings ON parent_inherited_settings.user_id = b.user_id
        AND parent_p.id = parent_inherited_settings.priority_id;

-- Recreate user_priority_unread (depends on user_priority_expanded)
CREATE OR REPLACE VIEW "public"."user_priority_unread" WITH ( security_invoker = TRUE)
AS
SELECT
    upe.user_id,
    upe.priority_id,
    TRUE AS unread,
    MAX(GREATEST (COALESCE(ar.updated_at, 'epoch'), CASE
        WHEN a.created_by = upe.user_id THEN COALESCE(a.last_note_created_at, 'epoch')
        ELSE COALESCE(a.last_note_created_at, a.created_at)
    END)) AS updated_at
FROM
    user_priority_expanded upe
    JOIN activity a ON a.priority_id = upe.priority_id
        AND a.archived_at IS NULL
        AND ((a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at)
            OR ((a.created_by IS NULL OR a.created_by != upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))
    LEFT JOIN activity_read ar ON ar.user_id = upe.user_id
        AND ar.activity_id = a.id
GROUP BY
    upe.user_id,
    upe.priority_id;

-- Recreate user_priority (depends on user_priority_unread)
CREATE OR REPLACE VIEW "public"."user_priority" WITH ( security_invoker = TRUE)
AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, coalesce(upu.updated_at, 'epoch')) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    pu.personal = TRUE
    AND p.id = root.id AS root,
    user_root.path @> p.path AS personal,
    COALESCE(settings.title, p.title) AS title,
    CASE
    WHEN inherited_settings.path IS NOT NULL THEN
        inherited_settings.path
    WHEN user_root.path @> p.path THEN
        p.path
    WHEN parent_inherited_settings.path IS NOT NULL THEN
        parent_inherited_settings.path || text(subpath (p.path, nlevel (p.path) - 1, 1))::ltree
    ELSE
        user_root.path || p.path
    END AS path,
    p.path AS global_path,
    settings.top_order,
    COALESCE(settings."order", extract(epoch FROM p.created_at) * 1000) AS "order",
    inherited_settings.pomodoro,
    inherited_settings.color,
    p.key,
    COALESCE(upu.unread, FALSE) AS unread
FROM
    priority_user pu
    JOIN priority root ON pu.priority_id = root.id
    JOIN priority_user pu_root ON pu.user_id = pu_root.user_id
        AND pu_root.personal = TRUE
    JOIN priority user_root ON pu_root.priority_id = user_root.id
    JOIN priority p ON root.path @> p.path
    LEFT JOIN priority parent_p ON nlevel (p.path) > 1
        AND parent_p.path = subpath (p.path, 0, nlevel (p.path) - 1)
    LEFT JOIN priority_settings_inherited parent_inherited_settings ON parent_inherited_settings.user_id = pu.user_id
        AND parent_p.id = parent_inherited_settings.priority_id
    LEFT JOIN priority_settings settings ON settings.user_id = pu.user_id
        AND p.id = settings.priority_id
    LEFT JOIN priority_settings_inherited inherited_settings ON inherited_settings.user_id = pu.user_id
        AND p.id = inherited_settings.priority_id
    LEFT JOIN user_priority_unread upu ON upu.user_id = pu.user_id
        AND upu.priority_id = p.id
WHERE
    pu.archived_at IS NULL;

-- Recreate user_priority trigger
CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

-- Recreate user_priority_actor (depends on user_priority_expanded, now uses upe.path)
CREATE OR REPLACE VIEW "public"."user_priority_actor" WITH ( security_invoker = TRUE)
AS
SELECT
    user_id,
    priority_path,
    actor_id,
    created_at,
    updated_at,
    archived_at
FROM (
    SELECT
        upe.user_id,
        upe.path AS priority_path,
        pc.contact_id AS actor_id,
        LEAST (COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
        GREATEST (pc.updated_at, c.updated_at) AS updated_at,
        CASE
            WHEN pc.invited_by IS NOT NULL AND pc.invited_at IS NULL THEN pc.updated_at
            ELSE c.archived_at
        END AS archived_at
    FROM
        user_priority_expanded upe
        JOIN priority_contact pc ON pc.priority_id = upe.priority_id
        JOIN contact c ON c.id = pc.contact_id
UNION ALL
SELECT
    upe.user_id,
    upe.path AS priority_path,
    pt.id AS actor_id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at
FROM
    user_priority_expanded upe
    JOIN priority_twist pt ON pt.priority_id = upe.priority_id) AS actors;

-- Recreate user_actor (depends on user_priority_actor)
CREATE OR REPLACE VIEW "public"."user_actor" WITH ( security_invoker = TRUE)
AS
WITH upa_agg AS (
    SELECT
        upa.user_id,
        upa.actor_id,
        COALESCE(MIN(upa.updated_at) FILTER (WHERE upa.archived_at IS NULL), MAX(upa.archived_at)) AS updated_at,
        CASE WHEN COUNT(*) FILTER (WHERE upa.archived_at IS NULL) = 0 THEN
            MAX(upa.archived_at)
        ELSE
            NULL
        END AS archived_at
    FROM
        user_priority_actor upa
    GROUP BY
        upa.user_id,
        upa.actor_id
)
SELECT
    ua.user_id,
    a.id,
    a.created_at,
    GREATEST (ua.updated_at, a.updated_at) AS updated_at,
    COALESCE(a.archived_at, ua.archived_at) AS archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    EXISTS (
        SELECT 1
        FROM contact c
        WHERE c.id = a.id
            AND c.user_id = ua.user_id
    ) AS self
FROM
    upa_agg ua
    JOIN actor a ON a.id = ua.actor_id;

-- Recreate user_twist (depends on user_priority_expanded)
CREATE OR REPLACE VIEW "public"."user_twist" WITH ( security_invoker = TRUE)
AS
SELECT
    upe.user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    pt.owner_id,
    pt.name,
    pt.config
FROM
    priority_twist pt
    JOIN user_priority_expanded upe ON upe.priority_id = pt.priority_id
    JOIN twist t ON pt.twist_id = t.id;

-- Recreate user_note (depends on user_priority_expanded)
CREATE OR REPLACE VIEW "public"."user_note"
AS
SELECT
    upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.mentions
FROM
    note n
    JOIN activity a ON a.id = n.activity_id
    JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id
WHERE
    (auth.uid() IS NULL OR upe.user_id = auth.uid())
    AND (n.draft = FALSE OR auth.uid() IS NULL OR n.created_by = auth.uid())
    AND (n.private = FALSE OR auth.uid() IS NULL
        OR n.created_by = auth.uid()
        OR auth.uid() = ANY(n.mentions))
    AND (a.draft = FALSE OR auth.uid() IS NULL OR a.created_by = auth.uid())
    AND (CASE WHEN a.private = FALSE THEN TRUE
        WHEN auth.uid() IS NULL THEN TRUE
        WHEN a.created_by = auth.uid() THEN TRUE
        ELSE public.user_mentioned_in_activity(auth.uid(), a.id)
    END)
UNION ALL
SELECT
    upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.activity_id,
    n.draft,
    n.private,
    NULL::text AS content,
    NULL::jsonb AS links,
    CAST(NULL AS uuid[]) AS mentions
FROM
    note n
    JOIN activity a ON a.id = n.activity_id
    JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id
WHERE
    auth.uid() IS NOT NULL
    AND upe.user_id = auth.uid()
    AND (n.draft = FALSE OR n.created_by = auth.uid())
    AND (a.draft = FALSE OR a.created_by = auth.uid())
    AND (
        (n.private = TRUE
            AND n.created_by != auth.uid()
            AND NOT (auth.uid() = ANY(COALESCE(n.mentions, CAST('{}' AS uuid[])))))
        OR
        (a.private = TRUE
            AND a.created_by != auth.uid()
            AND NOT public.user_mentioned_in_activity(auth.uid(), a.id))
    );

ALTER VIEW "public"."user_note" OWNER TO postgres;
REVOKE SELECT ON "public"."user_note" FROM anon;

-- Recreate user_activity (depends on user_priority_expanded)
CREATE OR REPLACE VIEW "public"."user_activity"
AS
SELECT
    upe.user_id,
    a.id,
    a.created_at,
    GREATEST (a.updated_at, COALESCE(a.last_note_created_at, 'epoch'::timestamptz),
        CASE WHEN a.archived_at IS NULL
            AND ((a.created_by = upe.user_id
                    AND a.last_note_created_at IS NOT NULL
                    AND a.last_note_created_at > upe.joined_at)
                OR ((a.created_by IS NULL
                        OR a.created_by != upe.user_id)
                    AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))
        THEN
            GREATEST (COALESCE(CASE WHEN ar.read_at >= (CASE WHEN a.created_by = upe.user_id THEN
                                a.last_note_created_at
                            ELSE
                                COALESCE(a.last_note_created_at, a.created_at)
                            END) THEN
                        ar.updated_at
                    END, 'epoch'::timestamptz), CASE WHEN a.created_by = upe.user_id THEN
                    COALESCE(a.last_note_created_at, 'epoch'::timestamptz)
                ELSE
                    COALESCE(a.last_note_created_at, a.created_at)
                END)
        ELSE
            'epoch'::timestamptz
        END) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
    CASE WHEN a.done_at IS NOT NULL THEN
        tstzrange(a.done_at, a.done_at, '[]')
    WHEN (a.assignee_id IS NOT NULL
        AND (
            SELECT
                c.user_id
            FROM
                contact c
            WHERE
                c.id = a.assignee_id) != upe.user_id)
        OR a."on" IS NULL THEN
        CASE WHEN LOWER(a.at) >= GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, 'epoch'::timestamptz)) THEN
            a.at
        ELSE
            tstzrange(GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, 'epoch'::timestamptz)), GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, 'epoch'::timestamptz)), '[]')
        END
    ELSE
        NULL::tstzrange
    END AS range_at,
    CASE WHEN a.done_at IS NOT NULL THEN
        NULL::daterange
    WHEN a.assignee_id IS NOT NULL
        AND (
            SELECT
                c.user_id
            FROM
                contact c
            WHERE
                c.id = a.assignee_id) != upe.user_id THEN
        NULL::daterange
    WHEN a.at IS NOT NULL THEN
        NULL::daterange
    WHEN a."on" IS NOT NULL THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on,
    COALESCE(CASE WHEN a.archived_at IS NULL
            AND ((a.created_by = upe.user_id
                    AND a.last_note_created_at IS NOT NULL
                    AND a.last_note_created_at > upe.joined_at)
                OR ((a.created_by IS NULL
                        OR a.created_by != upe.user_id)
                    AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at))
        THEN
            ar.read_at IS NULL
            OR ar.read_at < (CASE WHEN a.created_by = upe.user_id THEN
                    a.last_note_created_at
                ELSE
                    COALESCE(a.last_note_created_at, a.created_at)
                END)
        ELSE
            FALSE
        END, FALSE) AS unread
FROM
    activity_x a
    JOIN user_priority_expanded upe ON a.priority_id = upe.priority_id
    LEFT JOIN activity_read ar ON ar.user_id = upe.user_id
        AND ar.activity_id = a.id
WHERE
    (auth.uid() IS NULL OR upe.user_id = auth.uid())
    AND (a.draft = FALSE OR auth.uid() IS NULL OR a.created_by = auth.uid())
    AND (CASE WHEN a.private = FALSE THEN TRUE
        WHEN auth.uid() IS NULL THEN TRUE
        WHEN a.created_by = auth.uid() THEN TRUE
        ELSE public.user_mentioned_in_activity(auth.uid(), a.id)
    END)
UNION ALL
SELECT
    upe.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at, a.updated_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a.kind,
    a."order",
    a.draft,
    a.private,
    NULL::text AS title,
    NULL::text AS preview,
    NULL::tstzrange AS at,
    NULL::daterange AS "on",
    NULL::interval AS duration,
    a.done_at,
    NULL::text AS recurrence_rule,
    CAST(NULL AS timestamptz[]) AS recurrence_exdates,
    NULL::jsonb AS meta,
    NULL::text AS source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    CAST(NULL AS uuid[]) AS mentions,
    NULL::tstzrange AS range_at,
    NULL::daterange AS range_on,
    FALSE AS unread
FROM
    activity_x a
    JOIN user_priority_expanded upe ON a.priority_id = upe.priority_id
WHERE
    auth.uid() IS NOT NULL
    AND upe.user_id = auth.uid()
    AND (a.draft = FALSE OR a.created_by = auth.uid())
    AND a.private = TRUE
    AND a.created_by != auth.uid()
    AND NOT public.user_mentioned_in_activity(auth.uid(), a.id);

ALTER VIEW "public"."user_activity" OWNER TO postgres;
REVOKE SELECT ON "public"."user_activity" FROM anon;

-- Recreate user_activity_exception (depends on user_activity)
CREATE OR REPLACE VIEW "public"."user_activity_exception"
AS
SELECT
    ua.user_id,
    ae.id,
    ae.activity_id,
    COALESCE(ae.archived_at, ua.archived_at) AS archived_at,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    ae.at,
    ae.on,
    ae.title,
    ae.preview
FROM
    activity_exception ae
    JOIN user_activity ua ON ua.id = ae.activity_id;

ALTER VIEW "public"."user_activity_exception" OWNER TO postgres;
REVOKE SELECT ON "public"."user_activity_exception" FROM anon;

-- Recreate user_activity_tags (depends on user_activity)
CREATE OR REPLACE VIEW "public"."user_activity_tags"
AS
SELECT
    ua.user_id,
    ua.id,
    ua.archived_at,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
FROM
    activity_tags at
    JOIN user_activity ua ON ua.id = at.activity_id;

ALTER VIEW "public"."user_activity_tags" OWNER TO postgres;
REVOKE SELECT ON "public"."user_activity_tags" FROM anon;

-- Recreate user_note_tags (depends on user_activity)
CREATE OR REPLACE VIEW "public"."user_note_tags"
AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
FROM
    note_tags nt
    JOIN note n ON n.id = nt.note_id
    JOIN user_activity ua ON ua.id = n.activity_id
WHERE
    (n.draft = FALSE OR auth.uid() IS NULL OR n.created_by = auth.uid())
    AND (n.private = FALSE OR auth.uid() IS NULL
        OR n.created_by = auth.uid()
        OR auth.uid() = ANY(n.mentions));

ALTER VIEW "public"."user_note_tags" OWNER TO postgres;
REVOKE SELECT ON "public"."user_note_tags" FROM anon;

-- Recreate computed relationship function for user_activity
CREATE OR REPLACE FUNCTION public.actor (user_activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

