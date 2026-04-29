-- Thread schedule changes for threads created by each twist.
-- Used to dispatch onThreadToDo callbacks to sources.
--
-- NOTE: archived schedules are intentionally included. Removing a thread
-- from the agenda archives the schedule, and the connector needs the
-- resulting onThreadToDo(todo=false) dispatch to propagate the change
-- back to the external service (e.g. remove the Slack "Later" star).
-- Dispatchers derive `todo` from `archived_at` + `on`/`at`.
CREATE OR REPLACE VIEW "public"."twist_instance_thread_schedule"
AS
SELECT
    a.created_by AS twist_instance_id,
    s.thread_id,
    s.id AS schedule_id,
    s.user_id,
    s."on",
    s."at",
    s.archived_at,
    s.updated_at,
    s.seq,
    tp.priority_id
FROM
    twist_instance pt
    JOIN thread a ON a.created_by = pt.id
    LEFT JOIN thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
    JOIN schedule s ON s.thread_id = a.id
WHERE
    a.draft = FALSE
    AND pt.archived_at IS NULL
    AND s.user_id IS NOT NULL
    AND s.updated_at > pt.created_at
ORDER BY
    s.updated_at ASC;
