-- Aggregate note tags by note_id
CREATE OR REPLACE VIEW "public"."note_tags" --
AS
SELECT
    sq.note_id,
    jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL
        AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
    MAX(sq.updated_at) AS updated_at,
    (array_agg(sq.updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        nt.note_id,
        nt.tag_id,
        jsonb_agg(nt.actor_id) FILTER (WHERE nt.archived_at IS NULL) AS actor_ids,
        MAX(COALESCE(nt.archived_at, nt.updated_at)) AS updated_at,
        (array_agg(nt.updated_by ORDER BY nt.updated_at DESC))[1] AS updated_by
    FROM
        "public"."note_tag" nt
    GROUP BY
        nt.note_id,
        nt.tag_id) sq
GROUP BY
    sq.note_id;
