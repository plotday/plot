-- User-scoped link view
-- Shows links visible to the user via thread's or link's priority access
CREATE OR REPLACE VIEW "user"."link"
--
AS
SELECT
    upe.user_id,
    l.id,
    l.created_at,
    l.updated_at,
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
    l.priority_id,
    l.merged_from_thread_id,
    upe.path AS priority_path
FROM
    link_x l
    JOIN "user".priority_expanded upe ON l.priority_id = upe.priority_id;

ALTER VIEW "user"."link" OWNER TO postgres;
