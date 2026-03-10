-- While priority_user defines the priority roots for a user,
-- user.priority has a row for every priority (including children)
-- the user can access, with unread status.
CREATE OR REPLACE VIEW "user"."priority" -- for formatting
AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, coalesce(upu.updated_at, 'epoch')) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    (pu.personal = TRUE OR p.organization_id IS NOT NULL)
    AND p.id = root.id AS root,
    user_root.path @> p.path AS personal,
    COALESCE(settings.title, p.title) AS title,
    CASE
    -- Priority has explicit inherited settings
    WHEN inherited_settings.path IS NOT NULL THEN
        inherited_settings.path
        -- Priority's actual path is already under user's personal root
    WHEN user_root.path @> p.path THEN
        p.path
        -- Priority's parent has inherited settings - use parent's visual path + this priority's label
    WHEN parent_inherited_settings.path IS NOT NULL THEN
        parent_inherited_settings.path || text(subpath (p.path, nlevel (p.path) - 1, 1))::ltree
        -- Fallback: concatenate user root + actual path
    ELSE
        user_root.path || p.path
    END AS path,
    p.path AS global_path,
    settings.top_order,
    COALESCE(settings."order", extract(epoch FROM p.created_at) * 1000) AS "order",
    inherited_settings.pomodoro,
    inherited_settings.color,
    p.key,
    p.organization_id,
    COALESCE(upu.unread, FALSE) AS unread,
    "user".get_effective_role(pu.user_id, p.id) AS role
FROM
    priority_user pu
    JOIN priority root ON pu.priority_id = root.id
    JOIN priority_user pu_root ON pu.user_id = pu_root.user_id
        AND pu_root.personal = TRUE
    JOIN priority user_root ON pu_root.priority_id = user_root.id
    JOIN priority p ON root.path @> p.path
    -- Join parent priority to get its inherited settings for visual path computation
    LEFT JOIN priority parent_p ON nlevel (p.path) > 1
        AND parent_p.path = subpath (p.path, 0, nlevel (p.path) - 1)
    LEFT JOIN priority_settings_inherited parent_inherited_settings ON parent_inherited_settings.user_id = pu.user_id
        AND parent_p.id = parent_inherited_settings.priority_id
    LEFT JOIN priority_settings settings ON settings.user_id = pu.user_id
        AND p.id = settings.priority_id
    LEFT JOIN priority_settings_inherited inherited_settings ON inherited_settings.user_id = pu.user_id
        AND p.id = inherited_settings.priority_id
        -- Latest updated_at in descendant activities
    LEFT JOIN "user".priority_unread upu ON upu.user_id = pu.user_id
        AND upu.priority_id = p.id
WHERE
    pu.archived_at IS NULL;

