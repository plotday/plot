-- Threads that a twist should receive for the "update" callback
-- Only returns threads the twist created (created_by = priority_twist_id)
-- updated_at is aggregated with thread_tags to include tag changes
CREATE OR REPLACE VIEW "public"."priority_twist_thread_update" --
AS
SELECT
    a.created_by AS priority_twist_id,
    a.id,
    a.created_at,
    GREATEST (a.updated_at, COALESCE(at.updated_at, 'epoch'::timestamptz)) AS updated_at,
    a.created_by,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.draft,
    a.private,
    a.title,
    a.preview,
    public.get_thread_mentions (a.id) AS mentions,
    -- Enriched fields
    pc.title AS priority_title,
    at.tags
FROM
    priority_twist pt
    JOIN priority pp ON pp.id = pt.priority_id
    JOIN priority pc ON pc.path <@ pp.path
    JOIN thread a ON a.priority_id = pc.id
    LEFT JOIN thread_tags at ON at.thread_id = a.id
        AND at.occurrence IS NULL
WHERE
    a.draft = FALSE
    AND pt.id = a.created_by
    AND GREATEST (a.updated_at, COALESCE(at.updated_at, 'epoch'::timestamptz)) > a.created_at
    AND updated_by_uuid (pt.id) != a.updated_by
    AND pt.archived_at IS NULL
    AND GREATEST (a.updated_at, COALESCE(at.updated_at, 'epoch'::timestamptz)) > pt.created_at
ORDER BY
    GREATEST (a.updated_at, COALESCE(at.updated_at, 'epoch'::timestamptz)) ASC;
