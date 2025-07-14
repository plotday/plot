SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.agent_uuid ()
    RETURNS uuid
    LANGUAGE plpgsql
    AS $function$
DECLARE
    random_bytes bytea;
    uuid_text text;
BEGIN
    SELECT
        encode(gen_random_bytes(12), 'hex') INTO uuid_text;
    RETURN (uuid ('ab07ab07' || '-' || substring(uuid_text FROM 1 FOR 4) || '-' || substring(uuid_text FROM 3 FOR 4) || '-' || substring(uuid_text FROM 5 FOR 4) || '-' || substring(uuid_text FROM 7 FOR 12)));
END;
$function$;

ALTER TABLE "public"."activity"
    DROP CONSTRAINT "activity_created_by_fkey";

CREATE TABLE "public"."agent" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid_v7 (),
    "name" text NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone
);

ALTER TABLE "public"."agent" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."priority_agent" (
    "id" uuid NOT NULL DEFAULT agent_uuid (),
    "priority_id" uuid NOT NULL,
    "agent_id" uuid NOT NULL,
    "name" text NOT NULL,
    "config" jsonb NOT NULL DEFAULT '{}' ::jsonb,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone
);

ALTER TABLE "public"."priority_agent" ENABLE ROW LEVEL SECURITY;

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
    pc.child_id AS priority_child_id
FROM (priority_agent pa
    JOIN priority_children pc ON (pa.priority_id = pc.id));

CREATE UNIQUE INDEX agent_pkey ON public.agent USING btree (id);

CREATE INDEX idx_agent_priority_id ON public.priority_agent USING btree (priority_id);

CREATE UNIQUE INDEX priority_agent_pkey ON public.priority_agent USING btree (id);

ALTER TABLE "public"."agent"
    ADD CONSTRAINT "agent_pkey" PRIMARY KEY USING INDEX "agent_pkey";

ALTER TABLE "public"."priority_agent"
    ADD CONSTRAINT "priority_agent_pkey" PRIMARY KEY USING INDEX "priority_agent_pkey";

ALTER TABLE "public"."priority_agent"
    ADD CONSTRAINT "priority_agent_agent_id_fkey" FOREIGN KEY (agent_id) REFERENCES agent (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_agent" validate CONSTRAINT "priority_agent_agent_id_fkey";

ALTER TABLE "public"."priority_agent"
    ADD CONSTRAINT "priority_agent_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_agent" validate CONSTRAINT "priority_agent_priority_id_fkey";

CREATE POLICY "Allow all users to view agents" ON "public"."agent" AS permissive
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "Users can edit agents in their accessible priorities" ON "public"."priority_agent" AS permissive
    FOR ALL TO authenticated
        USING ((EXISTS (
            SELECT
                1
            FROM (priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id) OR (p.path <@ (
                    SELECT
                        priority.path
                    FROM
                        priority
                WHERE (priority.id = pu.priority_id))))))
            WHERE ((pu.user_id = auth.uid ()) AND (pu.deleted_at IS NULL) AND (priority_agent.priority_id = p.id)))));

CREATE TRIGGER set_agent_updated_at
    BEFORE UPDATE ON public.agent
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_agent_updated_at
    BEFORE UPDATE ON public.priority_agent
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW public.calendar_x SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW balance_without_children SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW "public"."agent_x" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."sync" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."user" SET ( security_invoker = FALSE);
