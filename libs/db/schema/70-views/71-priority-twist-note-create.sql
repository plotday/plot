-- Notes that a twist should receive for the "create" callback
-- A twist receives a note only if the twist is mentioned in that note's mentions array.
-- This is the sole routing mechanism — no implicit routing via thread ownership.
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
    n.thread_id,
    n.draft,
    n.private,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    -- Enriched fields
    a.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM
    priority_twist pt
    JOIN priority pp ON pp.id = pt.priority_id
    JOIN priority pc ON pc.path <@ pp.path
    JOIN thread a ON a.priority_id = pc.id
        AND a.archived_at IS NULL
    JOIN note n ON n.thread_id = a.id
        AND pt.id = ANY (n.mentions)
    LEFT JOIN actor author ON author.id = n.author_id
    LEFT JOIN note_tags nt ON nt.note_id = n.id
WHERE
    n.draft = FALSE
    AND n.created_by != pt.id
    AND updated_by_uuid (pt.id) != n.updated_by
    AND pt.archived_at IS NULL
    AND n.created_at > pt.created_at
ORDER BY
    n.created_at ASC;
