-- Notes that a twist should receive for the "create" callback
-- Filters by: twist created the activity OR twist is mentioned (including first mention)
-- For mentioned twists, only includes notes created on/after the first mention
--
-- Performance: Uses UNION ALL to split owned-activity notes from mentioned-activity notes.
-- This allows the planner to use different index strategies for each branch and avoids the
-- original correlated EXISTS subquery (which ran per-note and caused O(notes^2) scans).
-- The mention branch uses a LATERAL join to compute the earliest mention timestamp once
-- per activity instead of re-evaluating per note.
CREATE OR REPLACE VIEW "public"."priority_twist_note_create" --
AS
SELECT
    base.priority_twist_id,
    base.id,
    base.created_at,
    base.updated_at,
    base.source_created_at,
    base.author_id,
    base.created_by,
    base.updated_by,
    base.sync_depth,
    base.archived_at,
    base.activity_id,
    base.draft,
    base.private,
    base.content,
    base.links,
    base.key,
    base.mentions,
    base.re_note_id,
    -- Enriched fields
    base.priority_id,
    base.activity_title,
    base.activity_created_by,
    base.activity_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM (
    -- Branch 1: Notes on activities created by the twist
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
        a.priority_id,
        a.title AS activity_title,
        a.created_by AS activity_created_by,
        a.meta AS activity_meta
    FROM
        priority_twist pt
        JOIN priority pp ON pp.id = pt.priority_id
        JOIN priority pc ON pc.path <@ pp.path
        JOIN activity a ON a.priority_id = pc.id
            AND a.created_by = pt.id
            AND a.archived_at IS NULL
        JOIN note n ON n.activity_id = a.id
    WHERE
        n.draft = FALSE
        AND n.created_by != pt.id
        AND updated_by_uuid (pt.id) != n.updated_by
        AND pt.archived_at IS NULL
        AND n.created_at > pt.created_at

    UNION ALL

    -- Branch 2: Notes on activities where the twist is mentioned
    -- Uses a LATERAL join to find the earliest mention per activity,
    -- then includes notes created on/after that timestamp.
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
        a.priority_id,
        a.title AS activity_title,
        a.created_by AS activity_created_by,
        a.meta AS activity_meta
    FROM
        priority_twist pt
        JOIN priority pp ON pp.id = pt.priority_id
        JOIN priority pc ON pc.path <@ pp.path
        JOIN activity a ON a.priority_id = pc.id
            AND a.created_by != pt.id
            AND a.archived_at IS NULL
        -- Find the earliest mention of this twist in each activity
        JOIN LATERAL (
            SELECT MIN(m.created_at) AS first_mention_at
            FROM note m
            WHERE m.activity_id = a.id
              AND pt.id = ANY(m.mentions)
              AND m.archived_at IS NULL
        ) fm ON fm.first_mention_at IS NOT NULL
        JOIN note n ON n.activity_id = a.id
            AND n.created_at >= fm.first_mention_at
    WHERE
        n.draft = FALSE
        AND n.created_by != pt.id
        AND updated_by_uuid (pt.id) != n.updated_by
        AND pt.archived_at IS NULL
        AND n.created_at > pt.created_at
) base
LEFT JOIN actor author ON author.id = base.author_id
LEFT JOIN note_tags nt ON nt.note_id = base.id
ORDER BY
    base.created_at ASC;
