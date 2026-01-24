-- While priority_user defines the priority roots for a user,
-- user_priority has a row for every priority (including children)
-- the user can access, with unread status.
CREATE OR REPLACE VIEW "public"."user_priority" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    pu.user_id,
    p.id,
    p.created_at,
    GREATEST (settings.updated_at, pu.updated_at, p.updated_at, coalesce(upu.updated_at, 'epoch')) AS updated_at,
    GREATEST (pu.archived_at, p.archived_at) AS archived_at,
    p.created_by,
    p.updated_by,
    pu.personal = TRUE
    AND p.id = root.id AS root,
    p.title,
    CASE WHEN inherited_settings.path IS NOT NULL THEN
        inherited_settings.path
    WHEN user_root.path @> p.path THEN
        p.path
    ELSE
        user_root.path || p.path
    END AS path,
    settings.top_order,
    COALESCE(settings."order", extract(epoch FROM p.created_at) * 1000) AS "order",
    inherited_settings.pomodoro,
    inherited_settings.color,
    COALESCE(upu.unread, FALSE) AS unread
FROM
    priority_user pu
    JOIN priority root ON pu.priority_id = root.id
    JOIN priority_user pu_root ON pu.user_id = pu_root.user_id
        AND pu_root.personal = TRUE
    JOIN priority user_root ON pu_root.priority_id = user_root.id
    JOIN priority p ON root.path @> p.path
    LEFT JOIN priority_settings settings ON settings.user_id = pu.user_id
        AND p.id = settings.priority_id
    LEFT JOIN priority_settings_inherited inherited_settings ON inherited_settings.user_id = pu.user_id
        AND p.id = inherited_settings.priority_id
        -- Latest updated_at in descendant activities
    LEFT JOIN user_priority_unread upu ON upu.user_id = pu.user_id
        AND upu.priority_id = p.id
WHERE
    pu.archived_at IS NULL;

CREATE OR REPLACE FUNCTION public.handle_user_priority_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _priority_id uuid;
    _is_creator boolean;
    _priority_default_color integer;
BEGIN
    _priority_id := NEW.id;
    _is_creator := (NEW.created_by = COALESCE(auth.uid (), NEW.user_id));
    -- Get the priority's default color for initializing new priority_settings
    SELECT
        color INTO _priority_default_color
    FROM
        priority
    WHERE
        id = NEW.id;
    -- Update priority table fields (title, path, archived_at, updated_by)
    -- If creator is updating color, also update priority.color
    IF (OLD IS NULL OR NEW.archived_at IS DISTINCT FROM OLD.archived_at OR NEW.title IS DISTINCT FROM OLD.title OR NEW.path IS DISTINCT FROM OLD.path OR NEW.updated_by IS DISTINCT FROM OLD.updated_by OR (_is_creator AND NEW.color IS DISTINCT FROM OLD.color)) THEN
        INSERT INTO priority (id, archived_at, title, color, path, created_by, updated_by)
            VALUES (NEW.id, NEW.archived_at, NEW.title, CASE WHEN _is_creator THEN
                    NEW.color
                ELSE
                    NULL
                END, NEW.path, NEW.created_by, NEW.updated_by)
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = NEW.archived_at,
                title = NEW.title,
                color = CASE WHEN _is_creator THEN
                    NEW.color
                ELSE
                    priority.color
                END,
                path = NEW.path,
                updated_by = NEW.updated_by
            RETURNING
                id INTO _priority_id;
    END IF;
    -- Update priority_settings for user-specific inherited fields
    -- Always update priority_settings.color when color changes (for all users)
    -- Initialize color from priority.color if not provided by user
    IF ((OLD IS NULL AND (NEW."path" IS NOT NULL OR NEW."top_order" IS NOT NULL OR NEW."order" IS NOT NULL OR NEW."pomodoro" IS NOT NULL OR NEW."color" IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."path" IS DISTINCT FROM OLD."path" OR NEW."top_order" IS DISTINCT FROM OLD."top_order" OR NEW."order" IS DISTINCT FROM OLD."order" OR NEW."pomodoro" IS DISTINCT FROM OLD."pomodoro" OR NEW."color" IS DISTINCT FROM OLD."color"))) THEN
        INSERT INTO priority_settings (user_id, priority_id, path, top_order, "order", pomodoro, color)
            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.path, NEW.top_order, NEW.order, NEW.pomodoro, COALESCE(NEW.color, _priority_default_color))
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = COALESCE(NEW.path, priority_settings.path),
                top_order = COALESCE(NEW.top_order, priority_settings.top_order),
                "order" = COALESCE(NEW.order, priority_settings.order),
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

