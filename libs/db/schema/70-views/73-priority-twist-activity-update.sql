-- Activities that a twist should receive for the "update" callback
-- Only returns activities the twist created (created_by = priority_twist_id)
-- updated_at is aggregated with activity_tags to include tag changes
CREATE OR REPLACE VIEW "public"."priority_twist_activity_update" --
AS
SELECT
    a.created_by AS priority_twist_id,
    a.id,
    a.created_at,
    GREATEST (a.updated_at, COALESCE(at.updated_at, 'epoch'::timestamptz)) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.source,
    a.meta,
    public.get_activity_mentions (a.id) AS mentions,
    -- Enriched fields
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title,
    at.tags
FROM
    priority_twist pt
    JOIN priority pp ON pp.id = pt.priority_id
    JOIN priority pc ON pc.path <@ pp.path
    JOIN activity a ON a.priority_id = pc.id
    LEFT JOIN actor author ON author.id = a.author_id
    LEFT JOIN activity_tags at ON at.activity_id = a.id
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
