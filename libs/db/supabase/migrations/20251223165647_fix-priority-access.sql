SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.can_access_priority (_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.user_priority_expanded upe
            WHERE
                upe.user_id = auth.uid ()
                AND upe.priority_id = _priority_id);
$function$;

CREATE OR REPLACE FUNCTION public.can_access_priority (_priority_path ltree)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.priority_user pu
                JOIN public.priority p ON p.id = pu.priority_id
            WHERE
                pu.user_id = auth.uid ()
                AND p.path @> _priority_path);
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
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
