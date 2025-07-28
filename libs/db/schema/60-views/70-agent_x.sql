CREATE OR REPLACE VIEW "public"."agent_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    pa.*,
    a.tools,
    pc.child_id AS priority_child_id
FROM
    priority_agent pa
    JOIN priority_children pc ON pa.priority_id = pc.id
    JOIN agent a ON pa.agent_id = a.id;


