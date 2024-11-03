CREATE OR REPLACE VIEW note_x WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    note.*,
    activity.path AS activity_path,
    COALESCE(jsonb_object_agg(tag_users.emoji, tag_users.user_ids) FILTER (WHERE tag_users.emoji IS NOT NULL), '{}'::jsonb) AS tags
FROM
    note
    LEFT JOIN activity ON note.activity_id = activity.id
    LEFT JOIN (
        SELECT
            note_id,
            emoji,
            array_agg(user_id ORDER BY user_id) AS user_ids
        FROM
            tag
        GROUP BY
            note_id,
            emoji) AS tag_users ON note.id = tag_users.note_id
GROUP BY
    note.id,
    activity.path;

