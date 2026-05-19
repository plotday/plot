-- User-scoped link view
-- Shows links visible to the user via thread_priority (for thread-attached links)
-- or via priority ownership (for threadless links with their own priority_id)
CREATE OR REPLACE VIEW "user"."link"
--
AS
SELECT
    COALESCE(tp.user_id, p.user_id) AS user_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.seq,
    l.thread_id,
    l.source,
    l.source_created_at,
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
    l.logo,
    COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id), l.priority_id) AS priority_id,
    l.merged_from_thread_id,
    COALESCE(upe.path, pp.path) AS priority_path
FROM
    link l
    -- Thread-attached links: resolve priority via thread_priority. Apply
    -- the case-A visibility filter so pending rows behave the same as in
    -- user.thread (hidden when fresh, surfaced at root once the
    -- classify_visibility_window() elapses).
    LEFT JOIN thread_priority tp ON tp.thread_id = l.thread_id
        AND (
            tp.priority_id IS NOT NULL
            OR tp.classify_at < now() - public.classify_visibility_window()
        )
    LEFT JOIN "user".priority_expanded upe
        ON upe.user_id = tp.user_id
        AND upe.priority_id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
    -- Threadless links: use link's own priority_id
    LEFT JOIN priority pp ON pp.id = l.priority_id AND l.thread_id IS NULL
    LEFT JOIN priority p ON p.id = l.priority_id AND l.thread_id IS NULL
WHERE
    tp.user_id IS NOT NULL OR p.user_id IS NOT NULL;

