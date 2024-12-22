CREATE OR REPLACE VIEW "public"."activity_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    c2.id,
    cu.user_id,
    c2.created_at,
    c2.draft,
    GREATEST (cs.updated_at, cu.updated_at, c2.updated_at) AS updated_at,
    c2.name,
    replace_parent_path (c1.path, c2.path, COALESCE(cu.path, c1.path)) AS path,
    COALESCE(cs.order, (extract(epoch FROM CURRENT_TIMESTAMP) * 1000)::double PRECISION * 10) AS
ORDER,
cs.pomodoro AS pomodoro,
cs.color AS color
FROM
    activity_user cu
    JOIN activity c1 ON cu.activity_id = c1.id
    JOIN activity c2 ON c1.path @> c2.path
    LEFT JOIN activity_settings cs ON cs.user_id = cu.user_id
        AND c2.id = cs.activity_id;

CREATE OR REPLACE FUNCTION handle_activity_x_upsert ()
    RETURNS TRIGGER
    AS $$
DECLARE
    _activity_id uuid;
BEGIN
    _activity_id := NEW.id;
    IF (OLD IS NULL OR (NEW.name IS DISTINCT FROM OLD.name OR NEW.path IS DISTINCT FROM OLD.path)) THEN
        INSERT INTO activity (id, name, path, draft, created_by)
            VALUES (NEW.id, NEW.name, NEW.path, NEW.draft, auth.uid ())
        ON CONFLICT (id)
            DO UPDATE SET
                name = NEW.name, path = NEW.path, draft = NEW.draft
            RETURNING
                id INTO _activity_id;
    END IF;
    IF (OLD IS NULL AND (NEW.order IS NOT NULL OR NEW.pomodoro IS NOT NULL OR NEW.color IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."order" IS DISTINCT FROM OLD."order" OR NEW.pomodoro IS DISTINCT FROM OLD.pomodoro OR NEW.color IS DISTINCT FROM OLD.color)) THEN
        INSERT INTO activity_settings (user_id, activity_id, "order", pomodoro, color)
            VALUES (auth.uid (), _activity_id, NEW.order, COALESCE(NEW.pomodoro, 25 * 60), COALESCE(NEW.color, 0))
        ON CONFLICT (user_id, activity_id)
            DO UPDATE SET
                "order" = COALESCE(NEW.order, activity_settings."order"), pomodoro = COALESCE(NEW.pomodoro, activity_settings.pomodoro), color = COALESCE(NEW.color, activity_settings.color);
    END IF;
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

