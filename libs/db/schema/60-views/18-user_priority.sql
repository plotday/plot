-- Final user_priority view that combines user_priority_base with unread
CREATE OR REPLACE VIEW "public"."user_priority" WITH ( security_invoker = TRUE)
--
AS
SELECT
    upb.user_id,
    upb.id,
    upb.created_at,
    upb.updated_at,
    upb.archived_at,
    upb.created_by,
    upb.updated_by,
    upb.root,
    upb.title,
    upb.path,
    upb.top_order,
    upb.pomodoro,
    upb.color,
    COALESCE(pu.unread, FALSE) AS unread
FROM
    user_priority_base upb
    LEFT JOIN priority_unread pu ON pu.user_id = upb.user_id
        AND pu.priority_id = upb.id;

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
    IF ((OLD IS NULL AND (NEW."path" IS NOT NULL OR NEW."top_order" IS NOT NULL OR NEW."pomodoro" IS NOT NULL OR NEW."color" IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."path" IS DISTINCT FROM OLD."path" OR NEW."top_order" IS DISTINCT FROM OLD."top_order" OR NEW."pomodoro" IS DISTINCT FROM OLD."pomodoro" OR NEW."color" IS DISTINCT FROM OLD."color"))) THEN
        INSERT INTO priority_settings (user_id, priority_id, path, top_order, pomodoro, color)
            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.path, NEW.top_order, NEW.pomodoro, COALESCE(NEW.color, _priority_default_color))
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                path = COALESCE(NEW.path, priority_settings.path),
                top_order = COALESCE(NEW.top_order, priority_settings.top_order),
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

