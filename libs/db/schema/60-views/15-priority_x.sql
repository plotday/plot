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
    CASE WHEN pu.order IS NULL THEN
        p.ordered_at
    ELSE
        pu.updated_at
    END AS ordered_at,
    GREATEST (pu.deleted_at, p.deleted_at) AS deleted_at,
    p.created_by,
    p.draft,
    p.name,
    CASE WHEN pu.path IS NULL THEN
        -- If the user has no path, use the priority path
        p.path
    ELSE
        -- Otherwise, replace the parent path with the user's path
        replace_parent_path (p.path, pu.path, COALESCE(pu.path, p.path))
    END AS path,
    p.private,
    p.pinned,
    p.do_at,
    p.done_at,
    p.note,
    COALESCE(pu.order, p.order) AS "order",
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
    COALESCE(settings.is_default, FALSE) AS is_default,
    tags.tags AS tags
FROM
    priority_user pu
    JOIN priority root ON pu.priority_id = root.id
    JOIN priority p ON root.path @> p.path
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
    IF (OLD IS NULL OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at OR NEW.name IS DISTINCT FROM OLD.name OR NEW.path IS DISTINCT FROM OLD.path OR NEW.draft IS DISTINCT FROM OLD.draft OR NEW.private IS DISTINCT FROM OLD.private OR NEW.pinned IS DISTINCT FROM OLD.pinned OR NEW.expanded IS DISTINCT FROM OLD.expanded OR NEW.do_at IS DISTINCT FROM OLD.do_at OR NEW.done_at IS DISTINCT FROM OLD.done_at OR NEW.order IS DISTINCT FROM OLD.order OR NEW.ordered_at IS DISTINCT FROM OLD.ordered_at OR NEW.note IS DISTINCT FROM OLD.note) THEN
        INSERT INTO priority (id, deleted_at, name, path, draft, private, pinned, expanded, do_at, done_at, "order", ordered_at, note)
            VALUES (NEW.id, NEW.deleted_at, NEW.name, NEW.path, NEW.draft, NEW.private, NEW.pinned, NEW.expanded, NEW.do_at, NEW.done_at, NEW.order, NEW.ordered_at, NEW.note)
        ON CONFLICT (id)
            DO UPDATE SET
                deleted_at = NEW.deleted_at,
                name = NEW.name,
                path = NEW.path,
                draft = NEW.draft,
                private = NEW.private,
                pinned = NEW.pinned,
                expanded = NEW.expanded,
                do_at = NEW.do_at,
                done_at = NEW.done_at,
                "order" = NEW.order,
                ordered_at = NEW.ordered_at,
                note = NEW.note
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
    -- Remove previous default
    IF (NEW.is_default AND OLD IS NOT NULL AND NOT OLD.is_default) THEN
        UPDATE
            priority_settings
        SET
            is_default = FALSE
        WHERE
            is_default = TRUE
            AND user_id = COALESCE(auth.uid (), NEW.user_id);
    END IF;
    IF ((OLD IS NULL AND (NEW."pomodoro" IS NOT NULL OR NEW."color" IS NOT NULL OR NEW."is_default" IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."pomodoro" IS DISTINCT FROM OLD."pomodoro" OR NEW."color" IS DISTINCT FROM OLD."color" OR NEW."is_default" IS DISTINCT FROM OLD."is_default"))) THEN
        INSERT INTO priority_settings (user_id, priority_id, pomodoro, color, is_default)
            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.pomodoro, NEW.color, COALESCE(NEW.is_default, FALSE))
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                pomodoro = COALESCE(NEW.pomodoro, priority_settings.pomodoro),
                color = COALESCE(NEW.color, priority_settings.color),
                is_default = COALESCE(NEW.is_default, priority_settings.is_default);
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

