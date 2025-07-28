DROP TABLE "public"."agent" CASCADE;

CREATE TABLE "public"."agent" (
    "id" text NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "name" text NOT NULL,
    "description" text,
    "author_name" text,
    "author_email" text,
    "author_url" text,
    "tools" jsonb NOT NULL DEFAULT '{}' ::jsonb
);

ALTER TABLE "public"."agent" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."priority_agent"
    ALTER COLUMN "agent_id" SET data TYPE text USING "agent_id"::text;

CREATE UNIQUE INDEX agent_pkey ON public.agent USING btree (id);

ALTER TABLE "public"."agent"
    ADD CONSTRAINT "agent_pkey" PRIMARY KEY USING INDEX "agent_pkey";

ALTER TABLE "public"."priority_agent"
    ADD CONSTRAINT "priority_agent_agent_id_fkey" FOREIGN KEY (agent_id) REFERENCES agent (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_agent" validate CONSTRAINT "priority_agent_agent_id_fkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."agent_x" AS
SELECT
    pa.id,
    pa.priority_id,
    pa.agent_id,
    pa.name,
    pa.config,
    pa.created_at,
    pa.updated_at,
    pa.deleted_at,
    a.tools,
    pc.child_id AS priority_child_id
FROM ((priority_agent pa
        JOIN priority_children pc ON (pa.priority_id = pc.id))
    JOIN agent a ON (pa.agent_id = a.id));

CREATE OR REPLACE FUNCTION public.add_default_priority (user_id uuid)
    RETURNS void
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public', 'auth'
    AS $function$
DECLARE
    _priority_id uuid;
    payload jsonb;
    _plot_agent_id uuid;
    _priority_agent_id uuid;
    hmac_secret text;
    signature text;
BEGIN
    INSERT INTO public.priority (created_by, title, path, root)
        VALUES (user_id, 'Everything', public.generate_path (NULL), TRUE)
    RETURNING
        id INTO _priority_id;
    INSERT INTO public.priority_settings (user_id, priority_id)
        VALUES (user_id, _priority_id);
    SELECT
        id INTO _plot_agent_id
    FROM
        public.agent
    WHERE
        name = 'plot'
    LIMIT 1;
    IF _plot_agent_id IS NOT NULL THEN
        INSERT INTO public.priority_agent (priority_id, agent_id, name)
            VALUES (_priority_id, _plot_agent_id, 'Plot')
        RETURNING
            id INTO _priority_agent_id;
    END IF;
    payload := jsonb_build_object('agent_id', 'plot', 'priority_agent_id', _priority_agent_id, 'priority_id', _priority_id);
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(payload::text::bytea, hmac_secret::bytea, 'sha256'::text), 'hex');
    PERFORM
        net.http_post (url := public.get_api_root () || '/activate', body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
END;
$function$;

CREATE OR REPLACE FUNCTION public.notify_internal_api_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    event_type text;
    payload jsonb;
    api_url text;
    hmac_secret text;
    signature text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_type := 'created';
    ELSIF TG_OP = 'UPDATE' THEN
        event_type := 'updated';
    ELSIF TG_OP = 'DELETE' THEN
        event_type := 'deleted';
    END IF;
    -- Build the payload
    payload := jsonb_build_object('type', 'activity', 'event', event_type, 'item', CASE WHEN TG_OP = 'DELETE' THEN
            to_jsonb (OLD)
        ELSE
            to_jsonb (NEW)
        END, 'agents', (
            SELECT
                jsonb_agg(jsonb_build_object('agent_id', agent_id, 'priority_agent_id', id, 'config', config, 'tools', tools)) AS agents_jsonb FROM agent_x
            WHERE
                priority_child_id = COALESCE(NEW.priority_id, OLD.priority_id)
                AND id != COALESCE(NEW.created_by, OLD.created_by)), 'timestamp', extract(epoch FROM now()), 'table', 'activity');
    api_url := get_api_root () || '/update';
    hmac_secret := COALESCE(current_setting('plot.api_hmac_secret', TRUE), 'dev-not-secret');
    signature := encode(extensions.hmac(payload::text::bytea, hmac_secret::bytea, 'sha256'), 'hex');
    PERFORM
        net.http_post (url := api_url, body := payload, headers := jsonb_build_object('Content-Type', 'application/json', 'User-Agent', 'PostgreSQL/pg_net', 'X-Plot-Signature', 'sha256=' || signature));
    RETURN COALESCE(NEW, OLD);
END;
$function$;

CREATE POLICY "Allow all users to view agents" ON "public"."agent" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE TRIGGER set_agent_updated_at
    BEFORE UPDATE ON public.agent
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW gap SET (security_invoker = TRUE);

ALTER VIEW gap_monthly SET (security_invoker = TRUE);

ALTER VIEW gap_daily SET (security_invoker = TRUE);

ALTER VIEW insight SET (security_invoker = TRUE);

ALTER VIEW "admin"."sync" SET (security_invoker = FALSE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW "public"."event_invitees" SET (security_invoker = TRUE);

ALTER VIEW "public"."event_x" SET (security_invoker = TRUE);

ALTER VIEW public.calendar_x SET (security_invoker = TRUE);

ALTER VIEW "admin"."user" SET (security_invoker = FALSE);

ALTER VIEW balance_without_children SET (security_invoker = TRUE);

ALTER VIEW balance SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."agent_x" SET (security_invoker = TRUE);

