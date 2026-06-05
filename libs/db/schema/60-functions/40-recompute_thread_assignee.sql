-- Recompute thread.assignee_id for the given threads from their EARLIEST
-- assignment-capable (supports_assignee = true), non-archived link.
-- Threads with no capable link are left untouched (Plot-managed assignment).
-- The IS DISTINCT FROM guard avoids redundant writes (and redundant seq bumps),
-- which also makes the connector write-back loop-safe.
CREATE OR REPLACE FUNCTION public.recompute_thread_assignee(p_thread_ids uuid[])
    RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE thread t
    SET assignee_id = pc.assignee_id
    FROM (
        SELECT DISTINCT ON (l.thread_id) l.thread_id, l.assignee_id
        FROM link l
        WHERE l.thread_id = ANY (p_thread_ids)
          AND l.supports_assignee = true
          AND l.archived_at IS NULL
        ORDER BY l.thread_id, l.created_at ASC
    ) pc
    WHERE t.id = pc.thread_id
      AND t.assignee_id IS DISTINCT FROM pc.assignee_id;
END;
$$;
