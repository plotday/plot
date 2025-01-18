CREATE OR REPLACE VIEW note_x WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    note.*,
    (
        CASE WHEN note.pinned = TRUE THEN
            -- Pinned notes first
            1E14 + "note"."order"
        ELSE
            -- Everything else
            "note"."order"
        END) AS order_x,
    COALESCE(jsonb_object_agg(tag_users.emoji, tag_users.user_ids) FILTER (WHERE tag_users.emoji IS NOT NULL), '{}'::jsonb) AS tags
FROM
    note
    LEFT JOIN (
        SELECT
            item_id,
            emoji,
            array_agg(user_id ORDER BY user_id) AS user_ids
        FROM
            tag
        WHERE
            item_type = 'note'
        GROUP BY
            item_id,
            emoji) AS tag_users ON note.id = tag_users.item_id
GROUP BY
    note.id;

