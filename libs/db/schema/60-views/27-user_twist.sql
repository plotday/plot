-- User-accessible priority twists filtered by priority access
CREATE OR REPLACE VIEW "public"."user_twist" WITH ( security_invoker = TRUE)
--
AS
SELECT
    up.user_id,
    pt.id,
    pt.created_at,
    pt.updated_at,
    pt.archived_at,
    pt.priority_id,
    pt.twist_id,
    pt.twist_environment,
    pt.owner_id,
    pt.name,
    pt.config
FROM
    priority_twist pt
    JOIN user_priority up ON up.id = pt.priority_id;
