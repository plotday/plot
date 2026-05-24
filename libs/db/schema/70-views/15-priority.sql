-- Path-based descendant lookup, scoped per user. In the per-user priority
-- model every tree belongs to a single user, so finding children just
-- follows ltree containment within the same user_id. The legacy
-- inherit_members boundary is gone — cross-user boundaries are enforced
-- by the user_id filter.
CREATE OR REPLACE VIEW "public"."priority_child" -- for formatting
AS
SELECT
    p.id AS priority_id,
    c.id AS child_id,
    c.archived_at AS archived_at
FROM
    "public"."priority" p
    JOIN "public"."priority" c
        ON c.path <@ p.path
       AND c.user_id = p.user_id;

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
    JOIN priority p ON p.path <@ parent.path AND p.user_id = parent.user_id
    WHERE ps.key IN (
        'pomodoro', 'color',
        'respond_schedule_enabled', 'respond_window', 'respond_within',
        'early_notifications_enabled', 'notify_window', 'see_within'
    )
    UNION ALL
    -- Priority table color fallback (source_type = 1). Walks up each priority's
    -- own tree via path; no priority_user join needed because paths are scoped
    -- per user now.
    SELECT
        p.user_id,
        p.id AS priority_id,
        'color'::text AS key,
        to_jsonb(parent.color) AS value,
        parent.path AS source_path,
        parent.updated_at,
        nlevel(p.path) - nlevel(parent.path) AS distance,
        1 AS source_type
    FROM priority p
    JOIN priority parent ON p.path <@ parent.path AND parent.user_id = p.user_id
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

-- Returns twists accessible to a user across all environments.
-- Personal: twist.user_id = p_user_id.
-- Review: any twist_reviewer user.
-- Public: all users.
-- Private/review (non-public): members of the publisher group.
CREATE OR REPLACE FUNCTION public.get_accessible_twists (p_user_id uuid)
    RETURNS SETOF twist
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT DISTINCT
        twist.*
    FROM
        twist
    WHERE
        twist.archived_at IS NULL
        AND (
            twist.environment = 'public'
            OR (twist.environment = 'personal'
                AND twist.user_id = p_user_id)
            OR (twist.environment = 'review'
                AND EXISTS (SELECT 1 FROM twist_reviewer WHERE user_id = p_user_id))
            OR (twist.publisher_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM "group" g
                JOIN group_member gm ON gm.group_id = g.id
                JOIN user_contact uc ON uc.contact_id = gm.contact_id
                WHERE g.auto_publisher_id = twist.publisher_id
                  AND g.auto_maintained = TRUE
                  AND uc.user_id = p_user_id
                  AND uc.linked = TRUE
                  AND uc.archived_at IS NULL
            ))
        )
$function$;

CREATE OR REPLACE FUNCTION public.is_accessible_twist (p_twist_id bigint, p_user_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        EXISTS (
            SELECT 1
            FROM twist
            WHERE twist.id = p_twist_id
              AND twist.archived_at IS NULL
              AND (
                  twist.environment = 'public'
                  OR (twist.environment = 'personal'
                      AND twist.user_id = p_user_id)
                  OR (twist.environment = 'review'
                      AND EXISTS (SELECT 1 FROM twist_reviewer WHERE user_id = p_user_id))
                  OR (twist.publisher_id IS NOT NULL AND EXISTS (
                      SELECT 1 FROM "group" g
                      JOIN group_member gm ON gm.group_id = g.id
                      JOIN user_contact uc ON uc.contact_id = gm.contact_id
                      WHERE g.auto_publisher_id = twist.publisher_id
                        AND g.auto_maintained = TRUE
                        AND uc.user_id = p_user_id
                        AND uc.linked = TRUE
                        AND uc.archived_at IS NULL
                  ))
              )
        )
$function$;
