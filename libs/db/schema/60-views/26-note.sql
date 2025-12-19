-- User-accessible notes filtered by priority access
CREATE OR REPLACE VIEW "public"."user_note" WITH ( security_invoker = TRUE)
--
AS
SELECT
    upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.mentions
FROM
    note n
    JOIN activity a ON a.id = n.activity_id
    JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id;

-- Aggregate note tags by note_id
CREATE OR REPLACE VIEW "public"."note_tags" WITH ( security_invoker = TRUE)
--
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

-- User-accessible note tags
CREATE OR REPLACE VIEW "public"."user_note_tags" WITH ( security_invoker = TRUE)
--
AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
FROM
    note_tags nt
    JOIN note n ON n.id = nt.note_id
    JOIN user_activity ua ON ua.id = n.activity_id;

