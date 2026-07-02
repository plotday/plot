-- Per-user thread_state changes for threads created by each twist.
-- Used to dispatch onThreadToDo callbacks to sources.
--
-- The todo dimension is active/on/at only. `deriveScheduleTodo`
-- (workers/api/src/twist/tools/schedule-todo.ts) deliberately IGNORES read_at
-- — reading a starred thread must not clear the star. Cursor is per-dimension:
-- COALESCE(todo_seq, seq) advances only when active/on/at change, so a pure
-- read write no longer re-fires onThreadToDo. todo_source IS DISTINCT FROM the
-- twist_instance suppresses the connector's own synced-in star from echoing.
CREATE OR REPLACE VIEW "public"."twist_instance_thread_schedule"
AS
SELECT
    a.created_by AS twist_instance_id,
    ts.thread_id,
    ts.user_id,
    ts."on",
    ts."at",
    ts.active,
    ts.read_at,
    ts.updated_at,
    COALESCE(ts.todo_seq, ts.seq) AS seq,
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
    AND ts.todo_source IS DISTINCT FROM pt.id
ORDER BY
    COALESCE(ts.todo_seq, ts.seq) ASC;
