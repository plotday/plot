CREATE OR REPLACE VIEW "public"."priority_tags" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    a.priority_id,
    at.tag_id,
    COUNT(*) AS count,
    MAX(COALESCE(at.deleted_at, at.updated_at)) AS updated_at
FROM
    "public"."activity_tag" at
    JOIN "public"."activity" a ON at.activity_id = a.id
WHERE
    at.deleted_at IS NULL
    AND a.deleted_at IS NULL
    AND extensions.nlevel (a.path) = 1
GROUP BY
    a.priority_id,
    at.tag_id;

CREATE OR REPLACE VIEW "public"."priority_child" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    p.id AS priority_id,
    c.id AS child_id
FROM
    "public"."priority" p
    JOIN "public"."priority" c ON c.path <@ p.path;

-- While priority_user defines the priority roots for a user,
-- user_priority has a row for every priority (including children)
-- the user can access.
CREATE OR REPLACE VIEW "public"."user_priority" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at) AS updated_at,
    GREATEST (pu.deleted_at, p.deleted_at) AS deleted_at,
    p.created_by,
    p.updated_by,
    root.root
    AND p.id = root.id AS root,
    p.title,
    CASE WHEN root.root THEN
        -- If it's in a user's root, keep the path
        p.path
    ELSE
        -- Otherwise, replace the parent path with either the specified path, or the user's root
        COALESCE(pu.path, user_root.path) || subpath (p.path, extensions.nlevel (root.path))
    END AS path,
    CASE WHEN pu.priority_id = p.id THEN
        COALESCE(pu.order, p.order)
    ELSE
        p.order
    END AS "order",
    settings.pomodoro AS pomodoro,
    settings.color AS color
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
WHERE
    pu.deleted_at IS NULL;

CREATE OR REPLACE FUNCTION public.handle_user_priority_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _priority_id uuid;
BEGIN
    _priority_id := NEW.id;
    IF (OLD IS NULL OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at OR NEW.title IS DISTINCT FROM OLD.title OR NEW.path IS DISTINCT FROM OLD.path OR NEW.order IS DISTINCT FROM OLD.order OR NEW.updated_by IS DISTINCT FROM OLD.updated_by) THEN
        INSERT INTO priority (id, deleted_at, title, path, "order", created_by, updated_by)
            VALUES (NEW.id, NEW.deleted_at, NEW.title, NEW.path, NEW.order, NEW.created_by, NEW.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                deleted_at = NEW.deleted_at,
                title = NEW.title,
                path = NEW.path,
                "order" = NEW.order,
                updated_by = NEW.updated_by
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
$function$;

CREATE TRIGGER upsert_user_priority
    INSTEAD OF INSERT OR UPDATE ON user_priority
    FOR EACH ROW
    EXECUTE FUNCTION handle_user_priority_upsert ();

