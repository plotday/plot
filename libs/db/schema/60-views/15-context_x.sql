CREATE OR REPLACE VIEW "public"."context_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    c2.id,
    cu.user_id,
    GREATEST (cs.modified_at, cu.modified_at, c2.modified_at) AS modified_at,
    c2.name,
    replace_parent_path (c1.path, c2.path, COALESCE(cu.path, c1.path)) AS path,
    COALESCE(cs.order, (extract(epoch FROM CURRENT_TIMESTAMP) * 1000)::double PRECISION * 10) AS
ORDER,
COALESCE(cs.pomodoro, 25) AS pomodoro
FROM
    context_user cu
    JOIN context c1 ON cu.context_id = c1.id
    JOIN context c2 ON c1.path @> c2.path
    LEFT JOIN context_settings cs ON cs.user_id = cu.user_id
        AND c2.id = cs.context_id;

