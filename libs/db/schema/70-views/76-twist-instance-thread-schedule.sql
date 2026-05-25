-- Per-user thread_state changes for threads created by each twist.
-- Used to dispatch onThreadToDo callbacks to sources.
--
-- NOTE: rows are emitted even when `on`/`at` are cleared (no schedule).
-- Dispatchers derive `todo` from the presence of `on`/`at` and whether
-- read_at is set.
CREATE OR REPLACE VIEW "public"."twist_instance_thread_schedule"
AS
SELECT
    a.created_by AS twist_instance_id,
    ts.thread_id,
    ts.user_id,
    ts."on",
    ts."at",
    ts.active,
    ts.task,
    ts.to_read,
    ts.read_at,
    ts.updated_at,
    ts.seq,
    tp.priority_id
FROM
    twist_instance pt
    JOIN thread a ON a.created_by = pt.id
    JOIN thread_state ts ON ts.thread_id = a.id AND ts.user_id = pt.owner_id
    LEFT JOIN thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
WHERE
    a.draft = FALSE
    AND pt.archived_at IS NULL
    AND ts.updated_at > pt.created_at
ORDER BY
    ts.updated_at ASC;
