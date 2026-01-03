SET check_function_bodies = OFF;

DROP TRIGGER IF EXISTS "notify_api_for_activity_tag_change" ON "public"."activity_tag";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.set_created_at ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    seed_mode text;
BEGIN
    -- Check if plot.seed_mode is set (for seed scripts only)
    seed_mode := current_setting('plot.seed_mode', TRUE);
    IF seed_mode IS NOT NULL AND NEW.created_at IS NOT NULL THEN
        -- Seed mode: preserve the provided created_at timestamp
        RETURN NEW;
    ELSE
        -- Normal mode: set created_at to current time
        NEW.created_at = now();
        RETURN NEW;
    END IF;
END;
$function$;

CREATE TRIGGER notify_api_for_activity_tag_change
    AFTER INSERT OR UPDATE ON public.activity_tag
    FOR EACH ROW
    EXECUTE FUNCTION notify_for_activity_tag_change ();

ALTER VIEW "public"."user_note" SET (security_invoker = TRUE);

ALTER VIEW "public"."note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_twist" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_expanded" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

