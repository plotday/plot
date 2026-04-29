-- Individual tag change events for threads created by a twist
-- Returns rows for each tag add/remove event within a time range
-- Used to build tagsAdded/tagsRemoved for thread update callbacks
--
-- Usage: SELECT * FROM twist_instance_thread_tag_change
--   WHERE twist_instance_id = ? AND updated_at > start_time AND updated_at <= end_time
--
-- Then aggregate in code:
--   tagsAdded: group by thread_id, filter change_type='added', build {tag_id: [actor_ids]}
--   tagsRemoved: group by thread_id, filter change_type='removed', build {tag_id: [actor_ids]}
CREATE OR REPLACE VIEW "public"."twist_instance_thread_tag_change" --
AS
SELECT
    a.created_by AS twist_instance_id,
    at.thread_id,
    at.occurrence,
    at.tag_id,
    at.actor_id,
    at.updated_at,
    at.seq,
    CASE WHEN at.archived_at IS NULL THEN
        'added'
    ELSE
        'removed'
    END AS change_type
FROM
    thread_tag at
    JOIN thread a ON a.id = at.thread_id
    -- Only include tags on threads created by the twist itself
    JOIN twist_instance_details tid ON tid.id = a.created_by
WHERE
    a.draft = FALSE;
