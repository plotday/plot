-- Aggregate note reactions by note_id.
-- Mirrors note_tags's shape: { "<emoji>": [actor_id, ...], ... }
CREATE OR REPLACE VIEW "public"."note_reactions" --
AS
SELECT
    sq.note_id,
    jsonb_object_agg(sq.emoji, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL
        AND jsonb_array_length(sq.actor_ids) > 0) AS reactions,
    MAX(sq.updated_at) AS updated_at,
    MAX(sq.seq) AS seq,
    (array_agg(sq.updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        nr.note_id,
        nr.emoji,
        jsonb_agg(nr.actor_id) FILTER (WHERE nr.archived_at IS NULL) AS actor_ids,
        MAX(COALESCE(nr.archived_at, nr.updated_at)) AS updated_at,
        MAX(nr.seq) AS seq,
        (array_agg(nr.updated_by ORDER BY nr.updated_at DESC))[1] AS updated_by
    FROM
        "public"."note_reaction" nr
    GROUP BY
        nr.note_id,
        nr.emoji) sq
GROUP BY
    sq.note_id;

-- Aggregate thread reactions by (thread_id, occurrence).
CREATE OR REPLACE VIEW "public"."thread_reactions" --
AS
SELECT
    sq.thread_id,
    sq.occurrence,
    jsonb_object_agg(sq.emoji, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL
        AND jsonb_array_length(sq.actor_ids) > 0) AS reactions,
    MAX(sq.updated_at) AS updated_at,
    MAX(sq.seq) AS seq,
    (array_agg(sq.updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        tr.thread_id,
        tr.occurrence,
        tr.emoji,
        jsonb_agg(tr.actor_id) FILTER (WHERE tr.archived_at IS NULL) AS actor_ids,
        MAX(COALESCE(tr.archived_at, tr.updated_at)) AS updated_at,
        MAX(tr.seq) AS seq,
        (array_agg(tr.updated_by ORDER BY tr.updated_at DESC))[1] AS updated_by
    FROM
        "public"."thread_reaction" tr
    GROUP BY
        tr.thread_id,
        tr.occurrence,
        tr.emoji) sq
GROUP BY
    sq.thread_id,
    sq.occurrence;
