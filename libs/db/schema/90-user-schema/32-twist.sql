-- User-accessible priority twists filtered by priority access
CREATE OR REPLACE VIEW "user"."twist" --
AS
SELECT
    upe.user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    t.environment AS twist_environment,
    pt.owner_id,
    pt.name,
    pt.config
FROM
    priority_twist pt
    JOIN "user".priority_expanded upe ON upe.priority_id = pt.priority_id
    JOIN twist t ON pt.twist_id = t.id;
