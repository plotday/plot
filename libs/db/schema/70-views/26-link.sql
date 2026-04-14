-- link_x exposes the link's own priority_id (for threadless links).
-- Thread-attached links no longer inherit thread.priority_id here;
-- per-user resolution goes through thread_priority in user-schema views.
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
    l.logo,
    l.channel_id,
    l.merged_from_thread_id,
    l.priority_id,
    pp.path AS priority_path
FROM
    link l
    LEFT JOIN priority pp ON pp.id = l.priority_id;
