CREATE TABLE "public"."priority_agent" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "agent_id" uuid NOT NULL,
    "agent_environment" agent_environment NOT NULL,
    "owner_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "name" text NOT NULL,
    "config" jsonb NOT NULL DEFAULT '{}' ::jsonb,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    FOREIGN KEY (agent_id, agent_environment) REFERENCES public.agent (id, environment) ON DELETE CASCADE
);

CREATE INDEX idx_agent_priority_id ON "public"."priority_agent" ("priority_id");

CREATE INDEX idx_priority_agent_agent ON "public"."priority_agent" ("agent_id", "agent_environment");

ALTER TABLE "public"."priority_agent" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_agent_updated_at
    BEFORE UPDATE ON "public"."priority_agent"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

-- Function to set owner_id to current user on INSERT
CREATE OR REPLACE FUNCTION set_priority_agent_owner_id ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.owner_id := auth.uid ();
    RETURN NEW;
END;
$$
LANGUAGE plpgsql
SECURITY DEFINER;

CREATE TRIGGER set_priority_agent_owner_id
    BEFORE INSERT ON "public"."priority_agent"
    FOR EACH ROW
    EXECUTE FUNCTION set_priority_agent_owner_id ();

