SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.is_accessible_agent (p_agent_id uuid, p_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                agent
            LEFT JOIN agent_access ON agent.root_id = agent_access.agent_root_id
            LEFT JOIN user_priority ON user_priority.user_id = auth.uid ()
                AND user_priority.id = agent_access.priority_membership_id
        LEFT JOIN priority access_priority ON agent_access.priority_access_id = access_priority.id
        LEFT JOIN priority target_priority ON target_priority.id = p_priority_id
    WHERE
        agent.id = p_agent_id
        AND (agent.environment = 'public'
            OR (user_priority.id IS NOT NULL
                AND (agent_access.priority_access_id IS NULL
                    OR target_priority.path <@ access_priority.path)
                AND (agent_access.test = TRUE
                    OR agent.environment = 'private'))))
$function$;

CREATE POLICY "Users can view agents in accessible priorities" ON "public"."agent" AS permissive
    FOR SELECT TO authenticated
        USING ((EXISTS (
            SELECT
                1
            FROM
                priority_agent pa
            WHERE ((pa.agent_id = agent.id) AND can_access_priority (pa.priority_id)))));

CREATE POLICY "Users can view agent access" ON "public"."agent_access" AS permissive
    FOR SELECT TO authenticated
        USING ((EXISTS (
            SELECT
                1
            FROM (priority_agent pa
            JOIN agent a ON (pa.agent_id = a.id))
        WHERE ((a.root_id = agent_access.agent_root_id) AND can_access_priority (pa.priority_id)))));

CREATE POLICY "Users can view agent authors" ON "public"."agent_author" AS permissive
    FOR SELECT TO authenticated
        USING ((EXISTS (
            SELECT
                1
            FROM (agent a
            JOIN priority_agent pa ON (pa.agent_id = a.id))
        WHERE ((a.author_id = agent_author.id) AND can_access_priority (pa.priority_id)))));

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
