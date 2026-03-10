CREATE OR REPLACE VIEW "user"."priority_expanded" --
AS
WITH base AS (
    SELECT
        pu.user_id,
        c.child_id AS priority_id,
        MIN(pu.created_at) AS joined_at,
        LEAST (MIN(pu.archived_at), MIN(c.archived_at)) AS archived_at,
        CASE WHEN bool_or(pu.role = 'member') THEN 'member' ELSE 'viewer' END AS role
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
    b.role,
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
