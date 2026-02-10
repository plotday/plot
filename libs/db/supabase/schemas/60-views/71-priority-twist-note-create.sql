-- Notes that a twist should receive for the "create" callback
-- Filters by: twist created the activity OR twist is mentioned (including first mention)
-- For mentioned twists, only includes notes created on/after the first mention
CREATE OR REPLACE VIEW "public"."priority_twist_note_create" WITH ( security_invoker = TRUE)
--
AS
SELECT
    pct.id AS priority_twist_id,
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
    ax.priority_id,
    ax.title AS activity_title,
    ax.created_by AS activity_created_by,
    ax.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags,
    -- First mention timestamp for filtering notes after first mention
    fm.first_mentioned_at
FROM
    priority_child_twist pct
    JOIN activity_x ax ON ax.priority_id = pct.priority_child_id
    JOIN note n ON n.activity_id = ax.id
    LEFT JOIN actor author ON author.id = n.author_id
    LEFT JOIN note_tags nt ON nt.note_id = n.id
    LEFT JOIN LATERAL (
        SELECT
            MIN(note.created_at) AS first_mentioned_at
        FROM
            note
        WHERE
            note.activity_id = ax.id
            AND pct.id = ANY (note.mentions)
            AND note.archived_at IS NULL) fm ON TRUE
WHERE
    n.draft = FALSE
    AND updated_by_uuid (pct.id) != n.updated_by
    AND ax.archived_at IS NULL
    AND pct.archived_at IS NULL
    AND n.created_at > pct.created_at
    AND (
        -- Twist created the activity: get all notes
        ax.created_by = pct.id
        -- OR twist is mentioned: only notes on/after first mention
        OR (fm.first_mentioned_at IS NOT NULL
            AND n.created_at >= fm.first_mentioned_at))
ORDER BY
    n.created_at ASC;

