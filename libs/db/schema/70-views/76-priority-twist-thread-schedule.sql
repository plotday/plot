-- Thread schedule changes for threads created by each twist.
-- Used to dispatch onThreadToDo callbacks to sources.
-- Scoped by created_by so it works for sources (priority_twist.priority_id IS NULL).
CREATE OR REPLACE VIEW "public"."priority_twist_thread_schedule"
AS
SELECT
    a.created_by AS priority_twist_id,
    s.thread_id,
    s.id AS schedule_id,
    s.user_id,
    s."on",
    s."at",
    s.updated_at,
    a.priority_id
FROM
    priority_twist pt
    JOIN thread a ON a.created_by = pt.id
    JOIN schedule s ON s.thread_id = a.id
WHERE
    a.draft = FALSE
    AND pt.archived_at IS NULL
    AND s.user_id IS NOT NULL
    AND s.archived_at IS NULL
    AND s.updated_at > pt.created_at
ORDER BY
    s.updated_at ASC;
