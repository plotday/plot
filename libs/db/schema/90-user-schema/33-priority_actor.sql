-- user_priority_actor view
-- Shows all actors (contacts and priority twists) accessible to users through their priorities
-- One row per (user, priority, actor) combination
CREATE OR REPLACE VIEW "user"."priority_actor" --
AS
SELECT
    user_id,
    priority_path,
    actor_id,
    depth,
    created_at,
    updated_at,
    archived_at
FROM (
    -- Contacts associated with priorities via priority_contact (including ancestor priorities)
    SELECT user_id, priority_path, actor_id, depth, created_at, updated_at, archived_at
    FROM (
        SELECT DISTINCT ON (upe.user_id, upe.path, pc.contact_id)
            upe.user_id,
            upe.path AS priority_path,
            pc.contact_id AS actor_id,
            nlevel(p.path) - nlevel(ancestor.path) AS depth,
            LEAST (COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
            GREATEST (pc.updated_at, c.updated_at) AS updated_at,
            CASE
                WHEN pc.invited_by IS NOT NULL AND pc.invited_at IS NULL THEN pc.updated_at
                ELSE c.archived_at
            END AS archived_at
        FROM
            "user".priority_expanded upe
            JOIN priority p ON p.id = upe.priority_id
            JOIN priority ancestor ON p.path <@ ancestor.path
            JOIN "user".priority_expanded upe_ancestor
                ON upe_ancestor.user_id = upe.user_id
                AND upe_ancestor.priority_id = ancestor.id
            JOIN priority_contact pc ON pc.priority_id = ancestor.id
            JOIN contact c ON c.id = pc.contact_id
        WHERE NOT (upe_ancestor.role = 'viewer' AND c.user_id IS NOT NULL AND "user".get_effective_role(c.user_id, ancestor.id) = 'viewer')
          AND (c.user_id IS NULL OR c."primary" = true)
        ORDER BY upe.user_id, upe.path, pc.contact_id, nlevel(ancestor.path) DESC
    ) AS ancestor_contacts
UNION ALL
-- Priority twists bound directly to a priority
SELECT
    upe.user_id,
    upe.path AS priority_path,
    pt.id AS actor_id,
    0 AS depth,
    pt.created_at,
    pt.updated_at,
    pt.archived_at
FROM
    "user".priority_expanded upe
    JOIN priority_twist pt ON pt.priority_id = upe.priority_id
UNION ALL
-- Account-based sources (priority_twist.priority_id IS NULL)
-- linked to priorities via source_channel
SELECT
    upe.user_id,
    upe.path AS priority_path,
    pt.id AS actor_id,
    0 AS depth,
    pt.created_at,
    GREATEST (pt.updated_at, sc.updated_at) AS updated_at,
    pt.archived_at
FROM
    "user".priority_expanded upe
    JOIN source_channel sc ON sc.priority_id = upe.priority_id
    JOIN priority_twist pt ON pt.id = sc.priority_twist_id
        AND pt.priority_id IS NULL) AS actors;
