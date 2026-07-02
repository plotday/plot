-- Thread read status changes for threads created by each twist.
-- Used to dispatch onThreadRead callbacks to sources.
--
-- Cursor is per-dimension: COALESCE(read_seq, seq) advances only when read_at
-- actually changes, so an unrelated todo/importance write no longer re-fires
-- onThreadRead. read_source IS DISTINCT FROM the twist_instance suppresses the
-- connector's OWN synced-in read/unread from echoing back to it. This view is
-- intentionally NOT owner-scoped (the owner filter lives at connector dispatch;
-- the Plot-tool twist path consumes non-owner reads).
CREATE OR REPLACE VIEW "public"."twist_instance_thread_read"
AS
SELECT
    a.created_by AS twist_instance_id,
    tu.thread_id,
    tu.user_id,
    tu.read_at,
    tu.updated_at,
    COALESCE(tu.read_seq, tu.seq) AS seq,
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
    AND tu.read_source IS DISTINCT FROM pt.id
ORDER BY
    COALESCE(tu.read_seq, tu.seq) ASC;
