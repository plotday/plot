CREATE OR REPLACE VIEW "public"."context_x" WITH ( security_invoker = TRUE)
-- for formatting
AS
SELECT
    c2.id,
    cu.user_id,
    c2.created_at,
    GREATEST (cs.modified_at, cu.modified_at, c2.modified_at) AS modified_at,
    c2.name,
    replace_parent_path (c1.path, c2.path, COALESCE(cu.path, c1.path)) AS path,
    COALESCE(cs.order, (extract(epoch FROM CURRENT_TIMESTAMP) * 1000)::double PRECISION * 10) AS
ORDER,
COALESCE(cs.pomodoro, 25) AS pomodoro
FROM
    context_user cu
    JOIN context c1 ON cu.context_id = c1.id
    JOIN context c2 ON c1.path @> c2.path
    LEFT JOIN context_settings cs ON cs.user_id = cu.user_id
        AND c2.id = cs.context_id;

CREATE FUNCTION handle_context_x_insert ()
    RETURNS TRIGGER
    AS $$
DECLARE
    context_id uuid;
BEGIN
    context_id := NEW.id;
    IF context_id IS NULL THEN
        context_id := uuid_generate_v4 ();
    END IF;
    INSERT INTO context (id, name, path, created_by)
        VALUES (context_id, NEW.name, NEW.path, auth.uid ());
    IF NEW.order IS NOT NULL OR NEW.pomodoro IS NOT NULL THEN
        INSERT INTO context_settings (user_id, context_id, "order", pomodoro)
            VALUES (auth.uid (), context_id, NEW.order, COALESCE(NEW.pomodoro, 25));
    END IF;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE FUNCTION handle_context_x_update ()
    RETURNS TRIGGER
    AS $$
BEGIN
    IF NEW.name IS DISTINCT FROM OLD.name OR NEW.path IS DISTINCT FROM OLD.path THEN
        UPDATE
            context
        SET
            name = NEW.name,
            path = NEW.path
        WHERE
            id = NEW.id;
    END IF;
    IF NEW."order" IS DISTINCT FROM OLD."order" OR NEW.pomodoro IS DISTINCT FROM OLD.pomodoro THEN
        -- Upsert context_settings
        INSERT INTO context_settings (user_id, context_id, "order", pomodoro)
            VALUES (auth.uid (), NEW.id, NEW.order, COALESCE(NEW.pomodoro, 25))
        ON CONFLICT (user_id, context_id)
            DO UPDATE SET
                "order" = COALESCE(NEW.order, context_settings."order"), pomodoro = COALESCE(NEW.pomodoro, context_settings.pomodoro);
    END IF;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER insert_context_x
    INSTEAD OF INSERT ON context_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_context_x_insert ();

CREATE TRIGGER update_context_x
    INSTEAD OF UPDATE ON context_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_context_x_update ();

