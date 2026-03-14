-- Thread read status changes for threads created by each twist.
-- Used to dispatch onThreadRead callbacks to sources.
CREATE OR REPLACE VIEW "public"."priority_twist_thread_read"
AS
SELECT
    a.created_by AS priority_twist_id,
    tu.thread_id,
    tu.user_id,
    tu.read_at,
    tu.updated_at,
    a.priority_id
FROM
    priority_twist pt
    JOIN priority pp ON pp.id = pt.priority_id
    JOIN priority pc ON pc.path <@ pp.path
    JOIN thread a ON a.priority_id = pc.id
    JOIN thread_unread tu ON tu.thread_id = a.id
WHERE
    a.draft = FALSE
    AND pt.id = a.created_by
    AND pt.archived_at IS NULL
    AND tu.read_at IS NOT NULL
    AND tu.updated_at > pt.created_at
ORDER BY
    tu.updated_at ASC;
