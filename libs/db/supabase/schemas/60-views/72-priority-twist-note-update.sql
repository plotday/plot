-- Notes that a twist should receive for the "update" callback
-- Only returns notes the twist created (created_by = priority_twist_id)
-- updated_at is aggregated with note_tags to include tag changes
CREATE OR REPLACE VIEW "public"."priority_twist_note_update" WITH ( security_invoker = TRUE)
--
AS
SELECT
    n.created_by AS priority_twist_id,
    n.id,
    n.created_at,
    GREATEST (n.updated_at, COALESCE(nt.updated_at, 'epoch'::timestamptz)) AS updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.key,
    n.mentions,
    n.re_note_id,
    -- Enriched fields
    ax.priority_id,
    ax.title AS activity_title,
    ax.created_by AS activity_created_by,
    ax.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM
    priority_child_twist pct
    JOIN activity_x ax ON ax.priority_id = pct.priority_child_id
    JOIN note n ON ax.id = n.activity_id
    LEFT JOIN actor author ON author.id = n.author_id
    LEFT JOIN note_tags nt ON nt.note_id = n.id
WHERE
    n.draft = FALSE
    AND n.updated_at > n.created_at
    AND updated_by_uuid (pct.id) != n.updated_by
    AND ax.archived_at IS NULL
    AND pct.archived_at IS NULL
    AND n.updated_at > pct.created_at
ORDER BY
    n.updated_at ASC;

