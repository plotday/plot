CREATE OR REPLACE VIEW "public"."priority_tags" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    a.priority_id,
    at.tag_id,
    COUNT(*) AS count,
    MAX(COALESCE(at.archived_at, at.updated_at)) AS updated_at
FROM
    "public"."activity_tag" at
    JOIN "public"."activity" a ON at.activity_id = a.id
WHERE
    at.archived_at IS NULL
    AND a.archived_at IS NULL
GROUP BY
    a.priority_id,
    at.tag_id;

CREATE OR REPLACE VIEW "public"."priority_child" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    p.id AS priority_id,
    c.id AS child_id,
    c.archived_at AS archived_at
FROM
    "public"."priority" p
    JOIN "public"."priority" c ON c.path <@ p.path;

CREATE OR REPLACE VIEW "public"."user_priority_expanded" WITH ( security_invoker = TRUE)
--
AS
SELECT
    pu.user_id AS user_id,
    c.child_id AS priority_id,
    MIN(pu.created_at) AS joined_at,
    CASE WHEN bool_or(pu.archived_at IS NULL) THEN
        NULL
    ELSE
        LEAST (MIN(pu.archived_at), MIN(c.archived_at))
    END AS archived_at
FROM
    priority_user pu
    JOIN priority_child c ON pu.priority_id = c.priority_id
GROUP BY
    pu.user_id,
    c.child_id;

CREATE OR REPLACE VIEW "public"."priority_settings_inherited" WITH ( security_invoker = TRUE)
-- for formatting
AS
WITH inherited_sources AS (
    -- Get settings from priority_settings (user preferences)
    SELECT
        ps.user_id,
        p.id AS priority_id,
        nlevel (p.path) - nlevel (parent.path) AS distance,
        0 AS source_type, -- 0 = priority_settings has higher priority than priority.color
        CASE WHEN nlevel (p.path) > nlevel (parent.path)
            AND subpath (p.path, nlevel (parent.path)) != '' THEN
            ps.path || subpath (p.path, nlevel (parent.path))
        ELSE
            ps.path
        END AS path,
        ps.pomodoro,
        ps.color
    FROM
        priority_settings ps
        JOIN priority parent ON ps.priority_id = parent.id
        JOIN priority p ON p.path <@ parent.path
    WHERE
        ps.path IS NOT NULL
        OR ps.pomodoro IS NOT NULL
        OR ps.color IS NOT NULL
    UNION ALL
    -- Get default colors from priority table
    SELECT
        pu.user_id,
        p.id AS priority_id,
        nlevel (p.path) - nlevel (parent.path) AS distance,
        1 AS source_type, -- 1 = priority.color has lower priority
        NULL::ltree AS path,
        NULL::integer AS pomodoro,
        parent.color
    FROM
        priority_user pu
        JOIN priority root ON pu.priority_id = root.id
        JOIN priority p ON p.path <@ root.path
        JOIN priority parent ON p.path <@ parent.path
    WHERE
        parent.color IS NOT NULL
)
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
    distance ASC, -- Closest ancestor first
    source_type ASC;

-- priority_settings.color before priority.color at same distance
SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_accessible_twists (p_priority_id uuid)
    RETURNS SETOF twist
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT DISTINCT
        twist.*
    FROM
        twist
    LEFT JOIN twist_admin ON twist.id = twist_admin.id
WHERE
    twist.environment = 'public'
    OR (twist.environment = 'personal'
        AND twist.user_id = auth.uid ())
    OR can_access_priority (twist_admin.priority_id)
$function$;

CREATE OR REPLACE FUNCTION public.is_accessible_twist (p_twist_id uuid, p_twist_environment twist_environment, p_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                twist
            LEFT JOIN twist_admin ON twist.id = twist_admin.id
        WHERE
            twist.id = p_twist_id
            AND twist.environment = p_twist_environment
            AND (twist.environment = 'public'
                OR (twist.environment = 'personal'
                    AND twist.user_id = auth.uid ())
                OR can_access_priority (twist_admin.priority_id)))
$function$;

