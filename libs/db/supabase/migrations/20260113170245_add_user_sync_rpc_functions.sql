SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_pending_user_sync (p_user_id uuid)
    RETURNS TABLE (
        entity text,
        last_update_at timestamp with time zone)
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
    SELECT
        entity,
        last_update_at
    FROM
        user_sync
    WHERE
        user_id = p_user_id
        AND last_update_at > last_sync_at;
$function$;

CREATE OR REPLACE FUNCTION public.mark_user_sync_complete (p_user_id uuid)
    RETURNS void
    LANGUAGE sql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
    UPDATE
        user_sync
    SET
        last_sync_at = now()
    WHERE
        user_id = p_user_id
        AND last_update_at > last_sync_at;
$function$;

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
