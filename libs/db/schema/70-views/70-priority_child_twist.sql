-- All active twist_instances enriched with twist metadata.
-- Twists are now workspace-level (owned by a user), so there is no priority
-- subtree to walk — every twist_instance is visible to its owner across all
-- of their priorities.
CREATE OR REPLACE VIEW "public"."priority_child_twist" -- for formatting
AS
SELECT
    pt.*,
    t.version,
    t.environment AS twist_environment,
    t.is_source,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url
FROM
    twist_instance pt
    JOIN twist t ON pt.twist_id = t.id
    JOIN twist_admin ta ON t.twist_admin_id = ta.id
    LEFT JOIN publisher p ON ta.publisher_id = p.id
WHERE
    pt.archived_at IS NULL;

