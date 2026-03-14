CREATE OR REPLACE VIEW "public"."priority_tags" -- for formatting
AS
SELECT
    a.priority_id,
    at.tag_id,
    COUNT(*) AS count,
    MAX(COALESCE(at.archived_at, at.updated_at)) AS updated_at
FROM
    "public"."thread_tag" at
    JOIN "public"."thread" a ON at.thread_id = a.id
WHERE
    at.archived_at IS NULL
    AND a.archived_at IS NULL
GROUP BY
    a.priority_id,
    at.tag_id;

CREATE OR REPLACE VIEW "public"."priority_child" -- for formatting
AS
SELECT
    p.id AS priority_id,
    c.id AS child_id,
    c.archived_at AS archived_at
FROM
    "public"."priority" p
    JOIN "public"."priority" c ON c.path <@ p.path;

CREATE OR REPLACE VIEW "public"."priority_setting_inherited"
AS
WITH all_sources AS (
    -- User-specific settings (source_type = 0, wins over priority.color)
    SELECT
        ps.user_id,
        p.id AS priority_id,
        ps.key,
        ps.value,
        parent.path AS source_path,
        ps.updated_at,
        nlevel(p.path) - nlevel(parent.path) AS distance,
        0 AS source_type
    FROM priority_setting ps
    JOIN priority parent ON ps.priority_id = parent.id
    JOIN priority p ON p.path <@ parent.path
    WHERE ps.key IN ('pomodoro', 'color', 'path', 'attention_window', 'see_within_requests', 'see_within_updates')
    UNION ALL
    -- Priority table color fallback (source_type = 1)
    SELECT
        pu.user_id,
        p.id AS priority_id,
        'color'::text AS key,
        to_jsonb(parent.color) AS value,
        parent.path AS source_path,
        parent.updated_at,
        nlevel(p.path) - nlevel(parent.path) AS distance,
        1 AS source_type
    FROM priority_user pu
    JOIN priority root ON pu.priority_id = root.id
    JOIN priority p ON p.path <@ root.path
    JOIN priority parent ON p.path <@ parent.path
    WHERE parent.color IS NOT NULL
)
SELECT DISTINCT ON (user_id, priority_id, key)
    user_id,
    priority_id,
    key,
    value,
    source_path,
    updated_at
FROM all_sources
ORDER BY user_id, priority_id, key, distance ASC, source_type ASC;

CREATE OR REPLACE FUNCTION public.get_accessible_twists (p_priority_id uuid, p_user_id uuid)
    RETURNS SETOF twist
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT DISTINCT
        twist.*
    FROM
        twist
        JOIN twist_admin ON twist.twist_admin_id = twist_admin.id
    WHERE
        twist.archived_at IS NULL
        AND (
            twist.environment = 'public'
            OR (twist.environment = 'personal'
                AND twist_admin.user_id = p_user_id)
            OR user_has_priority_access (p_user_id, twist_admin.priority_id)
        )
$function$;

CREATE OR REPLACE FUNCTION public.is_accessible_twist (p_twist_id bigint, p_priority_id uuid, p_user_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                twist
                JOIN twist_admin ON twist.twist_admin_id = twist_admin.id
            WHERE
                twist.id = p_twist_id
                AND twist.archived_at IS NULL
                AND (twist.environment = 'public'
                    OR (twist.environment = 'personal'
                        AND twist_admin.user_id = p_user_id)
                    OR user_has_priority_access (p_user_id, twist_admin.priority_id)))
$function$;
