-- Activities that a twist should receive for the "update" callback
-- Only returns activities the twist created (created_by = priority_twist_id)
-- updated_at is aggregated with activity_tags to include tag changes
CREATE OR REPLACE VIEW "public"."priority_twist_activity_update" WITH ( security_invoker = TRUE)
--
AS
SELECT
    ax.created_by AS priority_twist_id,
    ax.id,
    ax.created_at,
    GREATEST (ax.updated_at, COALESCE(at.updated_at, 'epoch'::timestamptz)) AS updated_at,
    ax.source_created_at,
    ax.author_id,
    ax.created_by,
    ax.assignee_id,
    ax.updated_by,
    ax.sync_depth,
    ax.archived_at,
    ax.priority_id,
    ax.type,
    ax."order",
    ax.draft,
    ax.private,
    ax.title,
    ax.preview,
    ax.at,
    ax."on",
    ax.duration,
    ax.done_at,
    ax.recurrence_rule,
    ax.recurrence_exdates,
    ax.source,
    ax.meta,
    ax.mentions,
    -- Enriched fields
    author.name AS author_name,
    author.type AS author_type,
    p.title AS priority_title,
    at.tags
FROM
    priority_child_twist pct
    JOIN activity_x ax ON ax.priority_id = pct.priority_child_id
    LEFT JOIN actor author ON author.id = ax.author_id
    LEFT JOIN priority p ON p.id = ax.priority_id
    LEFT JOIN activity_tags at ON at.activity_id = ax.id
        AND at.occurrence IS NULL
WHERE
    ax.draft = FALSE
    AND pct.id = ax.created_by
    AND GREATEST (ax.updated_at, COALESCE(at.updated_at, 'epoch'::timestamptz)) > ax.created_at
    AND updated_by_uuid (pct.id) != ax.updated_by
    AND pct.archived_at IS NULL
    AND GREATEST (ax.updated_at, COALESCE(at.updated_at, 'epoch'::timestamptz)) > pct.created_at
ORDER BY
    GREATEST (ax.updated_at, COALESCE(at.updated_at, 'epoch'::timestamptz)) ASC;

