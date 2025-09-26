CREATE OR REPLACE VIEW "public"."priority_child_agent" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    pa.*,
    a.tools,
    pc.child_id AS priority_child_id
FROM
    priority_agent pa
    JOIN priority_child pc ON pa.priority_id = pc.priority_id
    JOIN agent a ON pa.agent_id = a.id;

