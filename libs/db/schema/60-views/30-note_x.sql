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

CREATE OR REPLACE FUNCTION handle_note_x_upsert ()
    RETURNS TRIGGER
    AS $$
BEGIN
    INSERT INTO note (user_id, id, draft, deleted_at, activity_id, body, pinned, "order", ordered_at, private)
        VALUES (auth.uid (), NEW.id, NEW.draft, NEW.deleted_at, NEW.activity_id, NEW.body, NEW.pinned, NEW."order", NEW.ordered_at, NEW.private)
    ON CONFLICT (id)
        DO UPDATE SET
            draft = NEW.draft, deleted_at = NEW.deleted_at, activity_id = NEW.activity_id, body = NEW.body, pinned = NEW.pinned, "order" = NEW."order", ordered_at = NEW.ordered_at, private = NEW.private;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER upsert_note_x
    INSTEAD OF INSERT OR UPDATE ON note_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_note_x_upsert ();

