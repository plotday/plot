CREATE OR REPLACE VIEW activity_x WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    activity.*,
    priority.path AS priority_path,
    (
        CASE WHEN activity.pinned = TRUE THEN
            -- Pinned notes first
            4E14 - "activity"."order"
        WHEN do_at <= NOW() THEN
            -- Current actions ordered first by when they were added.
            -- do_at epoch (seconds) shifted left by 1E3 and order (milliseconds)
            -- shifted right by 1E7 for a total of 1E10 between to avoid overlaps.
            2E14 - EXTRACT(EPOCH FROM do_at) * 1E3 - "activity"."order" / 1E7
        ELSE
            -- Everything else
            "activity"."order"
        END) AS order_x,
    COALESCE(jsonb_object_agg(tag_users.emoji, tag_users.user_ids) FILTER (WHERE tag_users.emoji IS NOT NULL), '{}'::jsonb) AS tags
FROM
    activity
    LEFT JOIN priority ON activity.priority_id = priority.id
    LEFT JOIN (
        SELECT
            item_id,
            emoji,
            array_agg(user_id ORDER BY user_id) AS user_ids
        FROM
            tag
        WHERE
            item_type = 'activity'
        GROUP BY
            item_id,
            emoji) AS tag_users ON activity.id = tag_users.item_id
GROUP BY
    activity.id,
    priority.path;

