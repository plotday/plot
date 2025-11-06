DROP TABLE "public"."priority_agent" CASCADE;

DROP TABLE "public"."agent" CASCADE;

DROP TRIGGER IF EXISTS "set_agent_access_updated_at" ON "public"."agent_access";

DROP TRIGGER IF EXISTS "set_agent_author_updated_at" ON "public"."agent_author";

DROP TRIGGER IF EXISTS "set_agent_token_updated_at" ON "public"."agent_token";

ALTER TABLE "public"."agent_access"
    DROP CONSTRAINT "agent_access_priority_access_id_fkey";

ALTER TABLE "public"."agent_access"
    DROP CONSTRAINT "agent_access_priority_membership_id_fkey";

ALTER TABLE "public"."agent_token"
    DROP CONSTRAINT "agent_token_priority_id_fkey";

DROP FUNCTION IF EXISTS "public"."is_accessible_agent" (p_agent_id uuid, p_priority_id uuid);

DROP FUNCTION IF EXISTS "public"."set_root_id_to_id" ();

ALTER TABLE "public"."agent_access"
    DROP CONSTRAINT "agent_access_pkey";

ALTER TABLE "public"."agent_author"
    DROP CONSTRAINT "agent_author_pkey";

ALTER TABLE "public"."agent_token"
    DROP CONSTRAINT "agent_token_pkey";

DROP INDEX IF EXISTS "public"."agent_access_pkey";

DROP INDEX IF EXISTS "public"."agent_author_pkey";

DROP INDEX IF EXISTS "public"."agent_token_pkey";

DROP TABLE "public"."agent_access";

DROP TABLE "public"."agent_author";

DROP TABLE "public"."agent_token";

ALTER TYPE "public"."agent_environment" RENAME TO "agent_environment__old_version_to_be_dropped";

CREATE TYPE "public"."agent_environment" AS enum (
    'personal',
    'private',
    'review',
    'public'
);

CREATE TABLE "public"."agent" (
    "id" uuid NOT NULL,
    "environment" agent_environment NOT NULL DEFAULT 'personal' ::agent_environment,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "name" text NOT NULL,
    "description" text,
    "user_id" uuid,
    "version" text NOT NULL
);

ALTER TABLE "public"."agent" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."agent_admin" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "publisher_id" bigint,
    "priority_id" uuid
);

ALTER TABLE "public"."agent_admin" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority_agent" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "priority_id" uuid NOT NULL,
    "agent_id" uuid NOT NULL,
    "agent_environment" agent_environment NOT NULL,
    "owner_id" uuid NOT NULL,
    "name" text NOT NULL,
    "config" jsonb NOT NULL DEFAULT '{}' ::jsonb,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone
);

ALTER TABLE "public"."priority_agent" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."publisher" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL,
    "email" text,
    "url" text
);

ALTER TABLE "public"."publisher" ENABLE ROW LEVEL SECURITY;

DROP TYPE "public"."agent_environment__old_version_to_be_dropped";

ALTER TABLE "public"."token"
    ADD COLUMN "publisher_id" bigint;

ALTER TABLE "public"."token"
    ALTER COLUMN "user_id" DROP NOT NULL;

CREATE UNIQUE INDEX agent_admin_pkey ON public.agent_admin USING btree (id);

CREATE UNIQUE INDEX agent_name_unique_public_review ON public.agent USING btree (name)
WHERE (environment = ANY (ARRAY['public'::agent_environment, 'review'::agent_environment]));

CREATE UNIQUE INDEX agent_pkey ON public.agent USING btree (id, environment);

CREATE INDEX idx_agent_priority_id ON public.priority_agent USING btree (priority_id);

CREATE INDEX idx_priority_agent_agent ON public.priority_agent USING btree (agent_id, agent_environment);

CREATE UNIQUE INDEX priority_agent_pkey ON public.priority_agent USING btree (id);

CREATE UNIQUE INDEX publisher_pkey ON public.publisher USING btree (id);

ALTER TABLE "public"."agent"
    ADD CONSTRAINT "agent_pkey" PRIMARY KEY USING INDEX "agent_pkey";

ALTER TABLE "public"."agent_admin"
    ADD CONSTRAINT "agent_admin_pkey" PRIMARY KEY USING INDEX "agent_admin_pkey";

ALTER TABLE "public"."priority_agent"
    ADD CONSTRAINT "priority_agent_pkey" PRIMARY KEY USING INDEX "priority_agent_pkey";

ALTER TABLE "public"."publisher"
    ADD CONSTRAINT "publisher_pkey" PRIMARY KEY USING INDEX "publisher_pkey";

ALTER TABLE "public"."agent"
    ADD CONSTRAINT "agent_id_fkey" FOREIGN KEY (id) REFERENCES agent_admin (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."agent" validate CONSTRAINT "agent_id_fkey";

ALTER TABLE "public"."agent"
    ADD CONSTRAINT "agent_owner_check" CHECK ((((environment = 'personal'::agent_environment) AND (user_id IS NOT NULL)) OR ((environment <> 'personal'::agent_environment) AND (user_id IS NULL)))) NOT valid;

ALTER TABLE "public"."agent" validate CONSTRAINT "agent_owner_check";

ALTER TABLE "public"."agent"
    ADD CONSTRAINT "agent_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."agent" validate CONSTRAINT "agent_user_id_fkey";

ALTER TABLE "public"."agent_admin"
    ADD CONSTRAINT "agent_admin_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."agent_admin" validate CONSTRAINT "agent_admin_priority_id_fkey";

ALTER TABLE "public"."agent_admin"
    ADD CONSTRAINT "agent_admin_publisher_id_fkey" FOREIGN KEY (publisher_id) REFERENCES publisher (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."agent_admin" validate CONSTRAINT "agent_admin_publisher_id_fkey";

ALTER TABLE "public"."priority_agent"
    ADD CONSTRAINT "priority_agent_agent_id_agent_environment_fkey" FOREIGN KEY (agent_id, agent_environment) REFERENCES agent (id, environment) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_agent" validate CONSTRAINT "priority_agent_agent_id_agent_environment_fkey";

ALTER TABLE "public"."priority_agent"
    ADD CONSTRAINT "priority_agent_owner_id_fkey" FOREIGN KEY (owner_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_agent" validate CONSTRAINT "priority_agent_owner_id_fkey";

ALTER TABLE "public"."priority_agent"
    ADD CONSTRAINT "priority_agent_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_agent" validate CONSTRAINT "priority_agent_priority_id_fkey";

ALTER TABLE "public"."token"
    ADD CONSTRAINT "token_owner_check" CHECK (((((user_id IS NOT NULL))::integer + ((publisher_id IS NOT NULL))::integer) = 1)) NOT valid;

ALTER TABLE "public"."token" validate CONSTRAINT "token_owner_check";

ALTER TABLE "public"."token"
    ADD CONSTRAINT "token_publisher_id_fkey" FOREIGN KEY (publisher_id) REFERENCES publisher (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."token" validate CONSTRAINT "token_publisher_id_fkey";

ALTER TABLE "public"."usage"
    ADD CONSTRAINT "usage_priority_agent_id_fkey" FOREIGN KEY (priority_agent_id) REFERENCES priority_agent (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."usage" validate CONSTRAINT "usage_priority_agent_id_fkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."actor" AS
SELECT
    c.id,
    c.created_at,
    c.updated_at,
    CASE WHEN (c.user_id IS NOT NULL) THEN
        'user'::text
    ELSE
        'contact'::text
    END AS type,
    COALESCE(c.name, c.email) AS name,
    c.email,
    c.avatar_url
FROM
    contact c
UNION ALL
SELECT
    pa.id,
    pa.created_at,
    pa.updated_at,
    'priority_agent'::text AS type,
    pa.name,
    NULL::text AS email,
    NULL::text AS avatar_url
FROM
    priority_agent pa;

CREATE OR REPLACE FUNCTION public.actor (activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

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
    LEFT JOIN agent_admin ON agent.id = agent_admin.id
WHERE
    agent.environment = 'public'
    OR (agent.environment = 'personal'
        AND agent.user_id = auth.uid ())
    OR can_access_priority (agent_admin.priority_id)
$function$;

CREATE OR REPLACE FUNCTION public.is_accessible_agent (p_agent_id uuid, p_agent_environment agent_environment, p_priority_id uuid)
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
            LEFT JOIN agent_admin ON agent.id = agent_admin.id
        WHERE
            agent.id = p_agent_id
            AND agent.environment = p_agent_environment
            AND (agent.environment = 'public'
                OR (agent.environment = 'personal'
                    AND agent.user_id = auth.uid ())
                OR can_access_priority (agent_admin.priority_id)))
$function$;

CREATE OR REPLACE VIEW "public"."priority_child_agent" AS
SELECT
    pa.id,
    pa.priority_id,
    pa.agent_id,
    pa.agent_environment,
    pa.owner_id,
    pa.name,
    pa.config,
    pa.created_at,
    pa.updated_at,
    pa.archived_at,
    a.version,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url,
    pc.child_id AS priority_child_id
FROM ((((priority_agent pa
                JOIN priority_child pc ON (pa.priority_id = pc.priority_id))
            JOIN agent a ON (((pa.agent_id = a.id)
                        AND (pa.agent_environment = a.environment))))
        LEFT JOIN agent_admin aa ON (a.id = aa.id))
    LEFT JOIN publisher p ON (aa.publisher_id = p.id));

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    agents_data jsonb;
    users_data jsonb;
    enriched_item jsonb;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
    current_item record;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
        current_item := NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
        current_item := NEW;
    ELSIF TG_OP = 'DELETE' THEN
        event_type := 'deleted';
        current_item := OLD;
    END IF;
    -- Extract agents query into a variable
    SELECT
        jsonb_agg(jsonb_build_object('id', agent_id, 'environment', agent_environment, 'version', version, 'priority_agent_id', id, 'config', config)) INTO agents_data
    FROM
        priority_child_agent
    WHERE
        priority_child_id = current_item.priority_id
        AND id != current_item.author_id;
    -- Get users who have access to this priority
    SELECT
        jsonb_agg(jsonb_build_object('user_id', user_id)) INTO users_data
    FROM
        public.get_users_with_priority_access (current_item.priority_id);
    -- Exit early if no agents or users found
    IF (agents_data IS NULL OR jsonb_array_length(agents_data) = 0) AND (users_data IS NULL OR jsonb_array_length(users_data) = 0) THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    -- Build enriched item with author and priority information
    SELECT
        jsonb_build_object('id', current_item.id, 'created_at', current_item.created_at, 'updated_at', current_item.updated_at, 'author_id', current_item.author_id, 'assignee_id', current_item.assignee_id, 'updated_by', current_item.updated_by, 'archived_at', current_item.archived_at, 'priority_id', current_item.priority_id, 'type', current_item.type, 'path', current_item.path, 'order', current_item.order, 'draft', current_item.draft, 'private', current_item.private, 'title', current_item.title, 'note', current_item.note, 'links', current_item.links, 'at', current_item.at, 'on', current_item.on, 'duration', current_item.duration, 'done_at', current_item.done_at, 'recurrence_rule', current_item.recurrence_rule, 'recurrence_exdates', current_item.recurrence_exdates, 'recurrence_dates', current_item.recurrence_dates, 'source', current_item.source,
            -- Enriched data from JOINs
            'author_name', a.name, 'author_type', a.type, 'priority_title', p.title) INTO enriched_item
    FROM
        actor a,
        priority p
    WHERE
        a.id = current_item.author_id
        AND p.id = current_item.priority_id;
    -- Build the payload
    payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', enriched_item, 'agents', COALESCE(agents_data, '[]'::jsonb), 'users', COALESCE(users_data, '[]'::jsonb), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(convert_to(payload::text, 'UTF8'), hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE POLICY "Users can view accessible agents" ON "public"."agent" AS permissive
    FOR SELECT TO authenticated
        USING (((environment = 'public'::agent_environment) OR ((environment = 'personal'::agent_environment) AND (user_id = auth.uid ())) OR (EXISTS (
            SELECT
                1
            FROM
                agent_admin aa
            WHERE ((aa.id = agent.id) AND can_access_priority (aa.priority_id))))));

CREATE POLICY "Users can delete agents in their accessible priorities" ON "public"."priority_agent" AS permissive
    FOR DELETE TO authenticated
        USING (can_access_priority (priority_id));

CREATE POLICY "Users can insert agents in their accessible priorities" ON "public"."priority_agent" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK ((can_access_priority (priority_id) AND (owner_id = auth.uid ())));

CREATE POLICY "Users can update agents in their accessible priorities" ON "public"."priority_agent" AS permissive
    FOR UPDATE TO authenticated
        USING (can_access_priority (priority_id))
        WITH CHECK ((can_access_priority (priority_id) AND (owner_id = auth.uid ())));

CREATE POLICY "Users can view agents in their accessible priorities" ON "public"."priority_agent" AS permissive
    FOR SELECT TO authenticated
        USING (can_access_priority (priority_id));

CREATE POLICY "Users can view agent publishers" ON "public"."publisher" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE TRIGGER set_agent_updated_at
    BEFORE UPDATE ON public.agent
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_agent_admin_updated_at
    BEFORE UPDATE ON public.agent_admin
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_agent_updated_at
    BEFORE UPDATE ON public.priority_agent
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_agent_owner_id
    BEFORE INSERT ON public.priority_agent
    FOR EACH ROW
    EXECUTE FUNCTION set_priority_agent_owner_id ();

CREATE TRIGGER set_publisher_updated_at
    BEFORE UPDATE ON public.publisher
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_agent" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

