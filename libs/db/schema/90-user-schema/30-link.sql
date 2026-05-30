-- User-scoped link view
-- Shows links visible to the user via thread_priority (for thread-attached links)
-- or via priority ownership (for threadless links with their own priority_id).
--
-- Connector-authored links (l.twist_id IS NOT NULL) are visible ONLY to the
-- user who owns the originating twist_instance. Two users' connections of the
-- same external resource each get their own link row attributed to their own
-- twist_instance, and each user sees only their own row. User-authored links
-- (l.twist_id IS NULL) remain shared across thread members.
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
    COALESCE("user".effective_priority_id(tp.priority_id, tp.user_id), l.priority_id) AS priority_id,
    l.merged_from_thread_id,
    COALESCE(upe.path, pp.path) AS priority_path
FROM
    link l
    -- Connector-authored links resolve through twist_instance to check ownership.
    -- When l.twist_id IS NOT NULL, link.created_by is a twist_instance_id (per
    -- the COMMENT on link.created_by in 25-link.sql).
    LEFT JOIN twist_instance ti
        ON ti.id = l.created_by
        AND l.twist_id IS NOT NULL
        AND ti.archived_at IS NULL
    -- Thread-attached links: resolve priority via thread_priority. Apply
    -- the case-A visibility filter so pending rows behave the same as in
    -- user.thread (hidden when fresh, surfaced at root once the
    -- classify_visibility_window() elapses).
    LEFT JOIN thread_priority tp ON tp.thread_id = l.thread_id
        AND tp.revoked_at IS NULL
        AND (
            tp.priority_id IS NOT NULL
            OR tp.classify_at < now() - public.classify_visibility_window()
        )
        -- Per-user gate for connector links: only the twist_instance owner sees them.
        -- User-authored links (twist_id IS NULL) stay shared across thread members.
        AND (l.twist_id IS NULL OR ti.owner_id = tp.user_id)
    LEFT JOIN "user".priority_expanded upe
        ON upe.user_id = tp.user_id
        AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id)
    -- Threadless links: use link's own priority_id
    LEFT JOIN priority pp ON pp.id = l.priority_id AND l.thread_id IS NULL
    LEFT JOIN priority p ON p.id = l.priority_id AND l.thread_id IS NULL
WHERE
    tp.user_id IS NOT NULL OR p.user_id IS NOT NULL;

