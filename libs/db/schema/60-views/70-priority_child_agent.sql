CREATE OR REPLACE VIEW "public"."priority_child_agent" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    pa.*,
    a.version,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url,
    pc.child_id AS priority_child_id
FROM
    priority_agent pa
    JOIN priority_child pc ON pa.priority_id = pc.priority_id
    JOIN agent a ON pa.agent_id = a.id AND pa.agent_environment = a.environment
    LEFT JOIN agent_admin aa ON a.id = aa.id
    LEFT JOIN publisher p ON aa.publisher_id = p.id;

