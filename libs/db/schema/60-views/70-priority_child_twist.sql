CREATE OR REPLACE VIEW "public"."priority_child_twist" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    pt.*,
    t.version,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url,
    pc.child_id AS priority_child_id
FROM
    priority_twist pt
    JOIN priority_child pc ON pt.priority_id = pc.priority_id
    JOIN twist t ON pt.twist_id = t.id AND pt.twist_environment = t.environment
    LEFT JOIN twist_admin ta ON t.id = ta.id
    LEFT JOIN publisher p ON ta.publisher_id = p.id
WHERE
    pt.archived_at IS NULL;

