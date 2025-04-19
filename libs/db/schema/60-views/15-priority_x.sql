CREATE OR REPLACE VIEW "public"."priority_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    c2.id,
    cu.user_id,
    c2.created_at,
    GREATEST (cs.updated_at, cu.updated_at, c2.updated_at) AS updated_at,
    GREATEST (cu.deleted_at, c2.deleted_at) AS deleted_at,
    c2.draft,
    c2.name,
    replace_parent_path (c1.path, c2.path, COALESCE(cs.path, c1.path)) AS path,
    COALESCE(cs.order, (extract(epoch FROM CURRENT_TIMESTAMP) * 1000)::double PRECISION * 10) AS
ORDER,
cs.pomodoro AS pomodoro,
cs.color AS color,
cs.is_default AS is_default
FROM
    priority_user cu
    JOIN priority c1 ON cu.priority_id = c1.id
    JOIN priority c2 ON c1.path @> c2.path
    LEFT JOIN priority_settings cs ON cs.user_id = cu.user_id
        AND c2.id = cs.priority_id;

CREATE OR REPLACE FUNCTION handle_priority_x_upsert ()
    RETURNS TRIGGER
    AS $$
DECLARE
    _priority_id uuid;
BEGIN
    _priority_id := NEW.id;
    IF (OLD IS NULL OR (NEW.name IS DISTINCT FROM OLD.name OR NEW.path IS DISTINCT FROM OLD.path OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at)) THEN
        INSERT INTO priority (id, name, path, draft, created_by, deleted_at)
            VALUES (NEW.id, NEW.name, NEW.path, NEW.draft, auth.uid (), NEW.deleted_at)
        ON CONFLICT (id)
            DO UPDATE SET
                name = NEW.name,
                path = NEW.path,
                draft = NEW.draft,
                deleted_at = NEW.deleted_at
            RETURNING
                id INTO _priority_id;
    END IF;
    IF (OLD IS NULL AND (NEW.order IS NOT NULL OR NEW.pomodoro IS NOT NULL OR NEW.color IS NOT NULL OR NEW.is_default IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."order" IS DISTINCT FROM OLD."order" OR NEW.pomodoro IS DISTINCT FROM OLD.pomodoro OR NEW.color IS DISTINCT FROM OLD.color OR NEW.is_default IS DISTINCT FROM OLD.is_default)) THEN
        INSERT INTO priority_settings (user_id, priority_id, "order", pomodoro, color, is_default)
            VALUES (auth.uid (), _priority_id, NEW.order, COALESCE(NEW.pomodoro, 25 * 60), COALESCE(NEW.color, 0), COALESCE(NEW.is_default, FALSE))
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                "order" = COALESCE(NEW.order, priority_settings."order"),
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

