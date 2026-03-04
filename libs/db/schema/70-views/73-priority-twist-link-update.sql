-- Links that a twist should receive for the "update" callback
-- Only returns links the twist created (created_by = priority_twist_id)
CREATE OR REPLACE VIEW "public"."priority_twist_link_update" --
AS
SELECT
    l.created_by AS priority_twist_id,
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
    t.priority_id,
    -- Enriched fields
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
FROM
    priority_twist pt
    JOIN priority pp ON pp.id = pt.priority_id
    JOIN priority pc ON pc.path <@ pp.path
    JOIN thread t ON t.priority_id = pc.id
    JOIN link l ON l.thread_id = t.id
    LEFT JOIN actor author ON author.id = l.author_id
WHERE
    t.draft = FALSE
    AND pt.id = l.created_by
    AND l.updated_at > l.created_at
    AND updated_by_uuid (pt.id) != l.updated_by
    AND pt.archived_at IS NULL
    AND l.updated_at > pt.created_at
ORDER BY
    l.updated_at ASC;
