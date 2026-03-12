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
    END AS path
FROM
    base b
    LEFT JOIN priority p ON p.id = b.priority_id
    LEFT JOIN priority_user pu_root ON b.user_id = pu_root.user_id
        AND pu_root.personal = TRUE
    LEFT JOIN priority user_root ON pu_root.priority_id = user_root.id
    LEFT JOIN (
        SELECT user_id, priority_id,
            MAX(CASE WHEN key = 'path' THEN value #>> '{}' END) AS path_value,
            MAX(CASE WHEN key = 'path' THEN text(source_path) END) AS path_source
        FROM priority_setting_inherited
        GROUP BY user_id, priority_id
    ) inherited ON inherited.user_id = b.user_id
        AND inherited.priority_id = b.priority_id;
