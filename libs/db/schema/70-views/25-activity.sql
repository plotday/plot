CREATE OR REPLACE VIEW "public"."activity_tags" --
AS
SELECT
    sq.activity_id,
    sq.occurrence,
    jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL
        AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
    MAX(sq.updated_at) AS updated_at,
    (array_agg(sq.updated_by ORDER BY sq.updated_at DESC))[1] AS updated_by
FROM (
    SELECT
        at.activity_id,
        at.occurrence,
        at.tag_id,
        jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
        MAX(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
        (array_agg(at.updated_by ORDER BY at.updated_at DESC))[1] AS updated_by
    FROM
        "public"."activity_tag" at
    GROUP BY
        at.activity_id,
        at.occurrence,
        at.tag_id) sq
GROUP BY
    sq.activity_id,
    sq.occurrence;

-- Add priority_path and mentions to activity view
-- Includes priority_path and mentions via get_activity_mentions()
CREATE OR REPLACE VIEW "public"."activity_x" --
AS
SELECT
    a.*,
    p.path AS priority_path,
    public.get_activity_mentions (a.id) AS mentions
FROM
    activity a
    JOIN priority p ON p.id = a.priority_id;
