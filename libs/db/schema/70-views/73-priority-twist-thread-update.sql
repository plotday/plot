-- Threads that a twist should receive for the "update" callback
-- Only returns threads the twist created (created_by = priority_twist_id)
-- updated_at is aggregated with thread_tags to include tag changes
-- Scoped by created_by so it works for sources (priority_twist.priority_id IS NULL).
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
    a.access,
    a.access_contacts,
    a.title,
    a.preview,
    -- Enriched fields
    pc.title AS priority_title,
    at.tags
FROM
    priority_twist pt
    JOIN thread a ON a.created_by = pt.id
    LEFT JOIN priority pc ON pc.id = a.priority_id
    LEFT JOIN thread_tags at ON at.thread_id = a.id
        AND at.occurrence IS NULL
WHERE
    a.draft = FALSE
    AND GREATEST (a.updated_at, COALESCE(at.updated_at, 'epoch'::timestamptz)) > a.created_at
    AND updated_by_uuid (pt.id) != a.updated_by
    AND pt.archived_at IS NULL
    AND GREATEST (a.updated_at, COALESCE(at.updated_at, 'epoch'::timestamptz)) > pt.created_at
ORDER BY
    GREATEST (a.updated_at, COALESCE(at.updated_at, 'epoch'::timestamptz)) ASC;
