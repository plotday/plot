-- user_priority_actor view
-- Shows all actors (contacts and priority twists) accessible to users through their priorities
-- One row per (user, priority, actor) combination
CREATE OR REPLACE VIEW "public"."user_priority_actor" WITH ( security_invoker = TRUE)
--
AS
SELECT
    user_id,
    priority_path,
    actor_id,
    created_at,
    updated_at,
    archived_at
FROM (
    -- Contacts associated with priorities via priority_contact
    SELECT
        upe.user_id,
        p.path AS priority_path,
        pc.contact_id AS actor_id,
        LEAST (COALESCE(pc.created_at, c.created_at), COALESCE(c.created_at, pc.created_at)) AS created_at,
        GREATEST (COALESCE(pc.created_at, c.updated_at), COALESCE(c.updated_at, pc.created_at)) AS updated_at,
        GREATEST (COALESCE(pc.archived_at, c.archived_at), COALESCE(c.archived_at, pc.archived_at)) AS archived_at
    FROM
        user_priority_expanded upe
        JOIN priority_contact pc ON pc.priority_id = upe.priority_id
        JOIN contact c ON c.id = pc.contact_id
        JOIN priority p ON p.id = pc.priority_id
UNION ALL
-- Priority twists (which are actors themselves)
SELECT
    upe.user_id,
    p.path AS priority_path,
    pt.id AS actor_id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at
FROM
    user_priority_expanded upe
    JOIN priority_twist pt ON pt.priority_id = upe.priority_id
    JOIN priority p ON p.id = pt.priority_id) AS actors;

