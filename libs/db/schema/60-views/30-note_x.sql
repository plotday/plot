CREATE OR REPLACE VIEW note_x WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    note.id,
    note.created_at,
    note.modified_at,
    note.user_id,
    note.context_id,
    note.topic_id,
    note.body,
    note.order,
    note.root,
    note.private,
    context.path AS context_path,
    jsonb_object_agg(tag_users.emoji, tag_users.user_ids) AS tags
FROM
    note
    LEFT JOIN context ON note.context_id = context.id
    LEFT JOIN (
        SELECT
            note_id,
            emoji,
            jsonb_agg(user_id) AS user_ids
        FROM
            tag
        GROUP BY
            note_id,
            emoji) AS tag_users ON note.id = tag_users.note_id
GROUP BY
    note.id,
    context.path;

