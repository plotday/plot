-- Activities that a twist should receive for the "create" callback
-- This view is similar to priority_twist_activity_update but uses created_at for filtering
CREATE OR REPLACE VIEW "public"."priority_twist_activity_create" WITH ( security_invoker = TRUE)
--
AS
SELECT
    ax.created_by AS priority_twist_id,
    ax.id,
    ax.created_at,
    ax.updated_at,
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
    AND pct.id != ax.created_by
    AND ax.archived_at IS NULL
    AND pct.archived_at IS NULL
    AND ax.created_at > pct.created_at
ORDER BY
    ax.created_at ASC;

