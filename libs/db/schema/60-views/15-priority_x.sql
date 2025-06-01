CREATE OR REPLACE VIEW "public"."priority_tags" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    priority_id,
    jsonb_object_agg(emoji, user_ids) AS tags
FROM (
    SELECT
        priority_id,
        emoji,
        jsonb_agg(user_id) AS user_ids
    FROM
        "public"."tag"
    GROUP BY
        priority_id,
        emoji) subquery
GROUP BY
    priority_id;

CREATE OR REPLACE VIEW "public"."priority_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    p.id,
    pu.user_id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at) AS updated_at,
    GREATEST (pu.deleted_at, p.deleted_at) AS deleted_at,
    p.created_by,
    root.root
    AND p.id = root.id AS root,
    p.draft,
    p.title,
    CASE WHEN root.root THEN
        -- If it's in a user's root, keep the path
        p.path
    ELSE
        -- Otherwise, replace the parent path with either the specified path, or the user's root
        COALESCE(pu.path, user_root.path) || subpath (p.path, extensions.nlevel (root.path))
    END AS path,
    p.private,
    p.pinned,
    p.do_at,
    p.done_at,
    p.note,
    p.event_series,
    CASE WHEN pu.priority_id = p.id
        AND pu.order IS NOT NULL THEN
        pu.order
    ELSE
        p.order
    END AS "order",
    (
        CASE WHEN p.pinned = TRUE THEN
            -- Pinned notes first
            4E14 - COALESCE(pu.order, p.order)
        WHEN p.do_at <= NOW() THEN
            -- Current actions ordered first by when they were added.
            -- do_at epoch (seconds) shifted left by 1E3 and order (milliseconds)
            -- shifted right by 1E7 for a total of 1E10 between to avoid overlaps.
            2E14 - EXTRACT(EPOCH FROM p.do_at) * 1E3 - COALESCE(pu.order, p.order) / 1E7
        ELSE
            -- Everything else
            COALESCE(pu.order, p.order)
        END) AS order_x,
    settings.pomodoro AS pomodoro,
    settings.color AS color,
    tags.tags AS tags
FROM
    -- User config for the root of p
    priority_user pu
    -- Priority root of p
    JOIN priority root ON pu.priority_id = root.id
    -- "Everything" priority for the user
    JOIN priority user_root ON pu.user_id = user_root.created_by
        AND user_root.root
        -- Every priority the user can access
    JOIN priority p ON root.path @> p.path
    -- Optional settings for the priority
    LEFT JOIN priority_settings settings ON settings.user_id = pu.user_id
        AND p.id = settings.priority_id
    LEFT JOIN priority_tags tags ON tags.priority_id = pu.priority_id;

CREATE OR REPLACE FUNCTION handle_priority_x_upsert ()
    RETURNS TRIGGER
    AS $$
DECLARE
    _priority_id uuid;
BEGIN
    _priority_id := NEW.id;
    IF (OLD IS NULL OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at OR NEW.title IS DISTINCT FROM OLD.title OR NEW.path IS DISTINCT FROM OLD.path OR NEW.draft IS DISTINCT FROM OLD.draft OR NEW.private IS DISTINCT FROM OLD.private OR NEW.pinned IS DISTINCT FROM OLD.pinned OR NEW.do_at IS DISTINCT FROM OLD.do_at OR NEW.done_at IS DISTINCT FROM OLD.done_at OR NEW.order IS DISTINCT FROM OLD.order OR NEW.note IS DISTINCT FROM OLD.note OR NEW.event_series IS DISTINCT FROM OLD.event_series) THEN
        INSERT INTO priority (id, deleted_at, title, path, draft, private, pinned, do_at, done_at, "order", note, event_series)
            VALUES (NEW.id, NEW.deleted_at, NEW.title, NEW.path, NEW.draft, NEW.private, NEW.pinned, NEW.do_at, NEW.done_at, NEW.order, NEW.note, NEW.event_series)
        ON CONFLICT (id)
            DO UPDATE SET
                deleted_at = NEW.deleted_at,
                title = NEW.title,
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
                id INTO _priority_id;
    END IF;
    IF ((OLD IS NULL AND NEW."order" IS NOT NULL) OR (OLD IS NOT NULL AND NEW."order" IS DISTINCT FROM OLD."order")) THEN
        UPDATE
            priority_user
        SET
            "order" = NEW.order
        WHERE
            user_id = COALESCE(auth.uid (), NEW.user_id)
            AND priority_id = _priority_id;
    END IF;
    -- TODO handle path update
    IF ((OLD IS NULL AND (NEW."pomodoro" IS NOT NULL OR NEW."color" IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."pomodoro" IS DISTINCT FROM OLD."pomodoro" OR NEW."color" IS DISTINCT FROM OLD."color"))) THEN
        INSERT INTO priority_settings (user_id, priority_id, pomodoro, color)
            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.pomodoro, NEW.color)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                pomodoro = COALESCE(NEW.pomodoro, priority_settings.pomodoro),
                color = COALESCE(NEW.color, priority_settings.color);
    END IF;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER upsert_priority_x
    INSTEAD OF INSERT OR UPDATE ON priority_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_priority_x_upsert ();

CREATE OR REPLACE VIEW "public"."priority_children" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    a.id,
    c.id AS child_id
FROM
    "public"."priority_x" a
    JOIN "public"."priority" c ON c.path <@ a.path;

