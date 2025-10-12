ALTER TABLE "public"."agent_access"
    DROP CONSTRAINT "agent_access_unique";

DROP FUNCTION IF EXISTS "public"."get_accessible_agents" (p_user_id uuid, p_priority_id uuid);

DROP INDEX IF EXISTS "public"."agent_access_unique";

CREATE UNIQUE INDEX agent_access_pkey ON public.agent_access USING btree (agent_root_id, priority_membership_id);

ALTER TABLE "public"."agent_access"
    ADD CONSTRAINT "agent_access_pkey" PRIMARY KEY USING INDEX "agent_access_pkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_accessible_agents (p_priority_id uuid)
    RETURNS SETOF agent
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT DISTINCT
        agent.*
    FROM
        agent
    LEFT JOIN agent_access ON agent.root_id = agent_access.agent_root_id
    LEFT JOIN user_priority ON user_priority.user_id = auth.uid ()
        AND user_priority.id = agent_access.priority_membership_id
    LEFT JOIN priority access_priority ON agent_access.priority_access_id = access_priority.id
    LEFT JOIN priority target_priority ON target_priority.id = p_priority_id
WHERE
    agent.environment = 'public'
    OR (user_priority.id IS NOT NULL
        AND (agent_access.priority_access_id IS NULL
            OR target_priority.path <@ access_priority.path)
        AND (agent_access.test = TRUE
            OR agent.environment = 'private'))
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
