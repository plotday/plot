-- Notes that a twist should receive for the "create" callback
-- Filters by: twist created the activity OR twist is mentioned (including first mention)
-- For mentioned twists, only includes notes created on/after the first mention
CREATE OR REPLACE VIEW "public"."priority_twist_note_create" --
AS
SELECT
    pt.id AS priority_twist_id,
    n.id,
    n.created_at,
    n.updated_at,
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
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM
    priority_twist pt
    JOIN priority pp ON pp.id = pt.priority_id
    JOIN priority pc ON pc.path <@ pp.path
    JOIN activity a ON a.priority_id = pc.id
    JOIN note n ON n.activity_id = a.id
    LEFT JOIN actor author ON author.id = n.author_id
    LEFT JOIN note_tags nt ON nt.note_id = n.id
WHERE
    n.draft = FALSE
    AND n.created_by != pt.id
    AND updated_by_uuid (pt.id) != n.updated_by
    AND a.archived_at IS NULL
    AND pt.archived_at IS NULL
    AND n.created_at > pt.created_at
    AND (
        -- Twist created the activity: get all notes
        a.created_by = pt.id
        -- OR twist is mentioned: only notes on/after first mention
        OR EXISTS (
            SELECT 1 FROM note m
            WHERE m.activity_id = a.id
              AND pt.id = ANY(m.mentions)
              AND m.archived_at IS NULL
              AND m.created_at <= n.created_at))
ORDER BY
    n.created_at ASC;
