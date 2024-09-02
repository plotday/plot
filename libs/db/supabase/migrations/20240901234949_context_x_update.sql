SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.handle_context_x_insert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.handle_context_x_update ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
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
$function$;

CREATE TRIGGER insert_context_x
    INSTEAD OF INSERT ON public.context_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_context_x_insert ();

CREATE TRIGGER update_context_x
    INSTEAD OF UPDATE ON public.context_x
    FOR EACH ROW
    EXECUTE FUNCTION handle_context_x_update ();

ALTER VIEW note_x SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
-- ALTER VIEW insight_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."invitation_admin" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."context_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."waitlist_admin" SET ( security_invoker = FALSE);
ALTER VIEW expenditure SET ( security_invoker = TRUE);
ALTER VIEW expenditure_weekly SET ( security_invoker = TRUE);
ALTER VIEW "public"."sync_admin" SET ( security_invoker = FALSE);
