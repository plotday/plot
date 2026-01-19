-- Individual tag change events for activities created by a twist
-- Returns rows for each tag add/remove event within a time range
-- Used to build tagsAdded/tagsRemoved for activity update callbacks
--
-- Usage: SELECT * FROM priority_twist_activity_tag_change
--   WHERE priority_twist_id = ? AND updated_at > start_time AND updated_at <= end_time
--
-- Then aggregate in code:
--   tagsAdded: group by activity_id, filter change_type='added', build {tag_id: [actor_ids]}
--   tagsRemoved: group by activity_id, filter change_type='removed', build {tag_id: [actor_ids]}
CREATE OR REPLACE VIEW "public"."priority_twist_activity_tag_change" WITH ( security_invoker = TRUE)
--
AS
SELECT
    a.created_by AS priority_twist_id,
    at.activity_id,
    at.occurrence,
    at.tag_id,
    at.actor_id,
    at.updated_at,
    CASE WHEN at.archived_at IS NULL THEN
        'added'
    ELSE
        'removed'
    END AS change_type
FROM
    activity_tag at
    JOIN activity a ON a.id = at.activity_id
    -- Only include tags on activities created by a twist that has access to this priority
    JOIN priority_child_twist pct ON pct.priority_child_id = a.priority_id
        AND pct.id = a.created_by
WHERE
    a.draft = FALSE;

