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
    a.priority_id,
    a.title AS activity_title,
    a.created_by AS activity_created_by,
    a.meta AS activity_meta,
    public.get_activity_mentions (a.id) AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM
    priority_twist pt
    JOIN priority pp ON pp.id = pt.priority_id
    JOIN priority pc ON pc.path <@ pp.path
    JOIN activity a ON a.priority_id = pc.id
    JOIN note n ON a.id = n.activity_id
    LEFT JOIN actor author ON author.id = n.author_id
    LEFT JOIN note_tags nt ON nt.note_id = n.id
WHERE
    n.draft = FALSE
    AND n.updated_at > n.created_at
    AND updated_by_uuid (pt.id) != n.updated_by
    AND a.archived_at IS NULL
    AND pt.archived_at IS NULL
    AND n.updated_at > pt.created_at
ORDER BY
    n.updated_at ASC;
