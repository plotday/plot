-- Add priority_path to link view (via thread's priority or direct priority)
CREATE OR REPLACE VIEW "public"."link_x" --
AS
SELECT
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.source_priority_root,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.channel_id,
    l.embedding,
    l.match,
    COALESCE(l.priority_id, t.priority_id) AS priority_id,
    COALESCE(pp.path, tp.path) AS priority_path
FROM
    link l
    LEFT JOIN thread t ON t.id = l.thread_id
    LEFT JOIN priority tp ON tp.id = t.priority_id
    LEFT JOIN priority pp ON pp.id = l.priority_id;
