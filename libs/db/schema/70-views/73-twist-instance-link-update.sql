-- Links that a twist should receive for the "update" callback
-- Only returns links the twist created (created_by = twist_instance_id)
CREATE OR REPLACE VIEW "public"."twist_instance_link_update" --
AS
SELECT
    l.created_by AS twist_instance_id,
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
    tp.priority_id,
    -- Enriched fields
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
FROM
    twist_instance pt
    JOIN link l ON l.created_by = pt.id
    JOIN thread t ON t.id = l.thread_id
    LEFT JOIN thread_priority tp ON tp.thread_id = t.id AND tp.user_id = pt.owner_id
    LEFT JOIN priority pc ON pc.id = tp.priority_id
    LEFT JOIN actor author ON author.id = l.author_id
WHERE
    t.draft = FALSE
    AND l.updated_at > l.created_at
    AND updated_by_uuid (pt.id) != l.updated_by
    AND pt.archived_at IS NULL
    AND l.updated_at > pt.created_at
ORDER BY
    l.updated_at ASC;
