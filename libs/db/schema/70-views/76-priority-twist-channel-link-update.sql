-- Links updated in source channels that a twist is observing.
-- Used to dispatch onLinkUpdated callbacks to twists with link permission.
CREATE OR REPLACE VIEW "public"."priority_twist_channel_link_update" --
AS
SELECT
    ptc.priority_twist_id,
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
    l.channel_id,
    l.source_url,
    t.priority_id,
    -- Enriched fields
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
FROM
    priority_twist_channel ptc
    JOIN link l ON l.created_by = ptc.source_priority_twist_id
        AND l.channel_id = ptc.channel_id
    JOIN thread t ON t.id = l.thread_id
    JOIN priority_twist pt ON pt.id = ptc.priority_twist_id
    JOIN priority pp ON pp.id = pt.priority_id
    JOIN priority pc ON pc.id = t.priority_id
        AND pc.path <@ pp.path
    LEFT JOIN actor author ON author.id = l.author_id
WHERE
    ptc.enabled = TRUE
    AND pt.archived_at IS NULL
    AND t.draft = FALSE
    AND l.updated_at > l.created_at
    AND updated_by_uuid (ptc.priority_twist_id) != l.updated_by
    AND l.updated_at > pt.created_at
ORDER BY
    l.updated_at ASC;
