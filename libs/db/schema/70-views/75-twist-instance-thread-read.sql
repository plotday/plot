-- Thread read status changes for threads created by each twist.
-- Used to dispatch onThreadRead callbacks to sources.
CREATE OR REPLACE VIEW "public"."twist_instance_thread_read"
AS
SELECT
    a.created_by AS twist_instance_id,
    tu.thread_id,
    tu.user_id,
    tu.read_at,
    tu.updated_at,
    tu.seq,
    tp.priority_id
FROM
    twist_instance pt
    JOIN thread a ON a.created_by = pt.id
    LEFT JOIN thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
    JOIN thread_state tu ON tu.thread_id = a.id
WHERE
    a.draft = FALSE
    AND pt.archived_at IS NULL
    AND tu.updated_at > pt.created_at
ORDER BY
    tu.updated_at ASC;
