-- Thread read status changes for threads created by each twist.
-- Used to dispatch onThreadRead callbacks to sources.
CREATE OR REPLACE VIEW "public"."priority_twist_thread_read"
AS
SELECT
    a.created_by AS priority_twist_id,
    tr.thread_id,
    tr.user_id,
    tr.read_at,
    tr.updated_at,
    a.priority_id
FROM
    priority_twist pt
    JOIN priority pp ON pp.id = pt.priority_id
    JOIN priority pc ON pc.path <@ pp.path
    JOIN thread a ON a.priority_id = pc.id
    JOIN thread_read tr ON tr.thread_id = a.id
WHERE
    a.draft = FALSE
    AND pt.id = a.created_by
    AND pt.archived_at IS NULL
    AND tr.updated_at > pt.created_at
ORDER BY
    tr.updated_at ASC;
