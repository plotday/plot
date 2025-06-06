CREATE OR REPLACE VIEW "public"."activity_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    a.id,
    pu.user_id,
    a.created_at,
    a.updated_at,
    a.deleted_at,
    a.created_by,
    a.priority_id,
    a.path,
    a.draft,
    a.private,
    a.pinned,
    a.do_at,
    a.done_at,
    a.note,
    a.event_series,
    a.order,
    (
        CASE WHEN a.pinned = TRUE THEN
            -- Pinned activities first
            4E14 - a.order
        WHEN a.do_at <= NOW() THEN
            -- Current actions ordered first by when they were added.
            -- do_at epoch (seconds) shifted left by 1E3 and order (milliseconds)
            -- shifted right by 1E7 for a total of 1E10 between to avoid overlaps.
            2E14 - EXTRACT(EPOCH FROM a.do_at) * 1E3 - a.order / 1E7
        ELSE
            -- Everything else
            a.order
        END) AS order_x
FROM
    -- User access to priorities
    priority_user pu
    -- Priority root of the activity's priority
    JOIN priority p ON pu.priority_id = p.id
        OR (p.path <@ (
                SELECT
                    path
                FROM
                    priority
            WHERE
                id = pu.priority_id))
    -- Activities under accessible priorities
    JOIN activity a ON a.priority_id = p.id
WHERE
    pu.deleted_at IS NULL
    AND p.deleted_at IS NULL;

CREATE OR REPLACE FUNCTION handle_activity_x_upsert ()
    RETURNS TRIGGER
    AS $$
DECLARE
    _activity_id uuid;
BEGIN
    _activity_id := NEW.id;
    -- Insert or update the activity
    INSERT INTO activity (id, deleted_at, priority_id, path, draft, private, pinned, do_at, done_at, "order", note, event_series)
        VALUES (NEW.id, NEW.deleted_at, NEW.priority_id, NEW.path, NEW.draft, NEW.private, NEW.pinned, NEW.do_at, NEW.done_at, NEW.order, NEW.note, NEW.event_series)
    ON CONFLICT (id)
        DO UPDATE SET
            deleted_at = NEW.deleted_at,
            priority_id = NEW.priority_id,
            path = NEW.path,
            draft = NEW.draft,
            private = NEW.private,
            pinned = NEW.pinned,
            do_at = NEW.do_at,
            done_at = NEW.done_at,
            "order" = NEW.order,
            note = NEW.note,
            event_series = NEW.event_series
        RETURNING
            id INTO _activity_id;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER upsert_activity_x
    INSTEAD OF INSERT OR UPDATE ON activity_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_activity_x_upsert ();

CREATE OR REPLACE VIEW "public"."activity_children" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    a.id,
    c.id AS child_id
FROM
    "public"."activity_x" a
    JOIN "public"."activity" c ON c.path <@ a.path;


