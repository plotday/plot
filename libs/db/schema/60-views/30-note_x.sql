CREATE OR REPLACE VIEW note_x WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    note.*,
    activity.path AS activity_path,
    (
        CASE WHEN pinned = TRUE THEN
            -- Pinned notes first
            "order"
        WHEN do_at <= NOW() THEN
            -- Current actions ordered first by when they were added.
            -- do_at epoch (seconds) shifted left by 1E3 and order (milliseconds)
            -- shifted right by 1E7 for a total of 1E10 between to avoid overlaps.
            1E14 + EXTRACT(EPOCH FROM do_at) * 1E3 + "order" / 1E7
        ELSE
            -- Everything else
            2E14 + "order"
        END) AS order_x,
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

CREATE OR REPLACE FUNCTION handle_note_x_upsert ()
    RETURNS TRIGGER
    AS $$
BEGIN
    INSERT INTO note (user_id, id, draft, archived_at, activity_id, topic_id, body, root, pinned, "order", ordered_at, private, do_at, done_at)
        VALUES (auth.uid (), NEW.id, NEW.draft, NEW.archived_at, NEW.activity_id, NEW.topic_id, NEW.body, NEW.root, NEW.pinned, NEW."order", NEW.ordered_at, NEW.private, NEW.do_at, NEW.done_at)
    ON CONFLICT (id)
        DO UPDATE SET
            draft = NEW.draft, archived_at = NEW.archived_at, activity_id = NEW.activity_id, topic_id = NEW.topic_id, body = NEW.body, root = NEW.root, pinned = NEW.pinned, "order" = NEW."order", ordered_at = NEW.ordered_at, private = NEW.private, do_at = NEW.do_at, done_at = NEW.done_at;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER upsert_note_x
    INSTEAD OF INSERT OR UPDATE ON note_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_note_x_upsert ();

