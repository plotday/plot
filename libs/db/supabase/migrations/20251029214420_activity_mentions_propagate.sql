SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.propagate_mentions_to_parent ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    parent_path ltree;
BEGIN
    -- Skip if this is already a top-level activity
    IF nlevel (NEW.path) = 1 THEN
        RETURN NEW;
    END IF;
    -- Skip if no mentions
    IF NEW.mentions IS NULL OR array_length(NEW.mentions, 1) IS NULL THEN
        RETURN NEW;
    END IF;
    -- Get top-level path (first segment only)
    parent_path := subpath (NEW.path, 0, 1);
    -- Update parent activity with deduplicated mentions
    -- Silently skips if parent not found (UPDATE affects 0 rows)
    UPDATE
        public.activity
    SET
        mentions = ARRAY ( SELECT DISTINCT
                unnest(COALESCE(mentions, ARRAY[]::uuid[]) || NEW.mentions))
    WHERE
        path = parent_path
        AND priority_id = NEW.priority_id
        AND archived_at IS NULL;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER activity_propagate_mentions_to_parent
    AFTER INSERT OR UPDATE OF mentions ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION propagate_mentions_to_parent ();

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_agent" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
