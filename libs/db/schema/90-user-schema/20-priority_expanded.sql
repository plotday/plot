-- user.priority_expanded — one row per priority, scoped by its single owner.
--
-- In the per-user model a priority belongs to exactly one user, so the
-- old priority_user / priority_child aggregation collapses to a simple
-- SELECT from priority with the user-specific path override applied
-- from priority_setting_inherited.
--
-- role is always 'member' for now — viewer is gone with the old access
-- model and may be reintroduced later via group contacts.
CREATE OR REPLACE VIEW "user"."priority_expanded" --
AS
SELECT
    p.user_id,
    p.id AS priority_id,
    p.created_at AS joined_at,
    p.archived_at,
    'member'::text AS role,
    CASE
        WHEN inherited.path_value IS NOT NULL THEN
            CASE WHEN inherited.path_source IS NOT NULL
                AND p.path != inherited.path_source::ltree
                AND subpath(p.path, nlevel(inherited.path_source::ltree)) != '' THEN
                inherited.path_value::ltree || subpath(p.path, nlevel(inherited.path_source::ltree))
            ELSE
                inherited.path_value::ltree
            END
        ELSE
            p.path
    END AS path
FROM
    priority p
    LEFT JOIN (
        SELECT user_id, priority_id,
            MAX(CASE WHEN key = 'path' THEN value #>> '{}' END) AS path_value,
            MAX(CASE WHEN key = 'path' THEN text(source_path) END) AS path_source
        FROM priority_setting_inherited
        GROUP BY user_id, priority_id
    ) inherited ON inherited.user_id = p.user_id
        AND inherited.priority_id = p.id;
