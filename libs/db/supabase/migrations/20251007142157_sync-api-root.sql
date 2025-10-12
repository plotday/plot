CREATE UNIQUE INDEX agent_name_unique_public_review ON public.agent USING btree (name)
WHERE (environment = ANY (ARRAY['public'::agent_environment, 'review'::agent_environment]));

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_api_root ()
    RETURNS text
    LANGUAGE plpgsql
    STABLE
    AS $function$
BEGIN
    RETURN COALESCE(current_setting('plot.api_root', TRUE), 'http://host.docker.internal:8787/sync');
END;
$function$;

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
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
