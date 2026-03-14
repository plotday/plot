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
    WHEN inherited.path_value IS NOT NULL THEN
        CASE WHEN inherited.path_source IS NOT NULL
            AND p.path != inherited.path_source::ltree
            AND subpath(p.path, nlevel(inherited.path_source::ltree)) != '' THEN
            inherited.path_value::ltree || subpath(p.path, nlevel(inherited.path_source::ltree))
        ELSE
            inherited.path_value::ltree
        END
    WHEN user_root.path @> p.path THEN
        p.path
    ELSE
        user_root.path || p.path
    END AS path,
    p.path AS global_path,
    settings.top_order,
    COALESCE(settings."order", extract(epoch FROM p.created_at) * 1000) AS "order",
    inherited.pomodoro,
    inherited.color,
    p.key,
    p.organization_id,
    COALESCE(upu.unread, FALSE) AS unread,
    "user".get_effective_role(pu.user_id, p.id) AS role,
    inherited.attention_window,
    inherited.see_within,
    COALESCE(settings.attention_window_set, FALSE) AS attention_window_set,
    COALESCE(settings.see_within_set, FALSE) AS see_within_set
FROM
    priority_user pu
    JOIN priority root ON pu.priority_id = root.id
    JOIN priority_user pu_root ON pu.user_id = pu_root.user_id
        AND pu_root.personal = TRUE
    JOIN priority user_root ON pu_root.priority_id = user_root.id
    JOIN priority p ON root.path @> p.path
    -- Direct settings (not inherited)
    LEFT JOIN (
        SELECT user_id, priority_id,
            MAX(CASE WHEN key = 'top_order' THEN (value #>> '{}')::double precision END) AS top_order,
            MAX(CASE WHEN key = 'order' THEN (value #>> '{}')::double precision END) AS "order",
            MAX(CASE WHEN key = 'title' THEN value #>> '{}' END) AS title,
            (MAX(CASE WHEN key = 'attention_window' THEN 1 END) IS NOT NULL) AS attention_window_set,
            (MAX(CASE WHEN key = 'see_within' THEN 1 END) IS NOT NULL) AS see_within_set,
            MAX(updated_at) AS updated_at
        FROM priority_setting
        GROUP BY user_id, priority_id
    ) settings ON settings.user_id = pu.user_id AND settings.priority_id = p.id
    -- Inherited settings (cascaded from ancestors)
    LEFT JOIN (
        SELECT user_id, priority_id,
            MAX(CASE WHEN key = 'pomodoro' THEN (value #>> '{}')::integer END) AS pomodoro,
            MAX(CASE WHEN key = 'color' THEN (value #>> '{}')::integer END) AS color,
            MAX(CASE WHEN key = 'attention_window' THEN value::text END)::jsonb AS attention_window,
            MAX(CASE WHEN key = 'see_within' THEN value::text END)::jsonb AS see_within,
            MAX(CASE WHEN key = 'path' THEN value #>> '{}' END) AS path_value,
            MAX(CASE WHEN key = 'path' THEN text(source_path) END) AS path_source
        FROM priority_setting_inherited
        GROUP BY user_id, priority_id
    ) inherited ON inherited.user_id = pu.user_id AND inherited.priority_id = p.id
    LEFT JOIN "user".priority_unread upu ON upu.user_id = pu.user_id
        AND upu.priority_id = p.id
WHERE
    pu.archived_at IS NULL;

