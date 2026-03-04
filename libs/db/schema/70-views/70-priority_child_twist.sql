CREATE OR REPLACE VIEW "public"."priority_child_twist" -- for formatting
AS
SELECT
    pt.*,
    t.version,
    t.environment AS twist_environment,
    t.is_source,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url,
    pc.child_id AS priority_child_id
FROM
    priority_twist pt
    JOIN priority_child pc ON pt.priority_id = pc.priority_id
    JOIN twist t ON pt.twist_id = t.id
    JOIN twist_admin ta ON t.twist_admin_id = ta.id
    LEFT JOIN publisher p ON ta.publisher_id = p.id
WHERE
    pt.archived_at IS NULL;

