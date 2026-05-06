-- Threads that a twist should receive for the "update" callback
-- Only returns threads the twist created (created_by = twist_instance_id).
-- Split into two halves so the outer query's seq filter pushes down:
--   Half A: thread.* itself changed (driven by idx_thread_created_by_seq)
--   Half B: a thread_tag changed for an owned thread (driven by idx_thread_tag_seq)
-- Both halves can emit a row for the same thread when both seqs land in the
-- consumer's window. TwistSync dedupes those by id (max seq) before dispatch.
CREATE OR REPLACE VIEW "public"."twist_instance_thread_update" --
AS
-- Half A: the thread row itself changed
SELECT
    a.created_by AS twist_instance_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.seq,
    a.created_by,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    tp.priority_id,
    a.draft,
    a.contacts,
    a.title,
    a.preview,
    pc.title AS priority_title,
    at.tags
FROM
    twist_instance pt
    JOIN thread a ON a.created_by = pt.id
    LEFT JOIN thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
    LEFT JOIN priority pc ON pc.id = tp.priority_id
    LEFT JOIN thread_tags at ON at.thread_id = a.id
        AND at.occurrence IS NULL
WHERE
    a.draft = FALSE
    AND a.updated_at > a.created_at
    AND updated_by_uuid (pt.id) != a.updated_by
    AND pt.archived_at IS NULL
    AND a.updated_at > pt.created_at

UNION ALL

-- Half B: a thread_tag changed for an owned thread
SELECT
    a.created_by AS twist_instance_id,
    a.id,
    a.created_at,
    COALESCE(tt.archived_at, tt.updated_at) AS updated_at,
    tt.seq,
    a.created_by,
    tt.updated_by,
    a.sync_depth,
    a.archived_at,
    tp.priority_id,
    a.draft,
    a.contacts,
    a.title,
    a.preview,
    pc.title AS priority_title,
    at.tags
FROM
    thread_tag tt
    JOIN thread a ON a.id = tt.thread_id
    JOIN twist_instance pt ON pt.id = a.created_by
    LEFT JOIN thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
    LEFT JOIN priority pc ON pc.id = tp.priority_id
    LEFT JOIN thread_tags at ON at.thread_id = a.id
        AND at.occurrence IS NULL
WHERE
    tt.occurrence IS NULL
    AND a.draft = FALSE
    AND COALESCE(tt.archived_at, tt.updated_at) > a.created_at
    AND updated_by_uuid (pt.id) != tt.updated_by
    AND pt.archived_at IS NULL
    AND COALESCE(tt.archived_at, tt.updated_at) > pt.created_at;
