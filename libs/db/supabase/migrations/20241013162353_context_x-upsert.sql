DROP TRIGGER IF EXISTS "insert_context_x" ON "public"."context_x";

DROP TRIGGER IF EXISTS "update_context_x" ON "public"."context_x";

DROP FUNCTION IF EXISTS "public"."handle_context_x_insert" ();

DROP FUNCTION IF EXISTS "public"."handle_context_x_update" ();

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.handle_context_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _context_id uuid;
BEGIN
    _context_id := NEW.id;
    IF (OLD IS NULL OR (NEW.name IS DISTINCT FROM OLD.name OR NEW.path IS DISTINCT FROM OLD.path)) THEN
        INSERT INTO context (id, name, path, created_by)
            VALUES (NEW.id, NEW.name, NEW.path, auth.uid ())
        ON CONFLICT (id)
            DO UPDATE SET
                name = NEW.name, path = NEW.path
            RETURNING
                id INTO _context_id;
    END IF;
    IF (OLD IS NULL AND (NEW.order IS NOT NULL OR NEW.pomodoro IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."order" IS DISTINCT FROM OLD."order" OR NEW.pomodoro IS DISTINCT FROM OLD.pomodoro)) THEN
        INSERT INTO context_settings (user_id, context_id, "order", pomodoro)
            VALUES (auth.uid (), _context_id, NEW.order, COALESCE(NEW.pomodoro, 25))
        ON CONFLICT (user_id, context_id)
            DO UPDATE SET
                "order" = COALESCE(NEW.order, context_settings."order"), pomodoro = COALESCE(NEW.pomodoro, context_settings.pomodoro);
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER upsert_context_x
    INSTEAD OF INSERT OR UPDATE ON public.context_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_context_x_upsert ();

