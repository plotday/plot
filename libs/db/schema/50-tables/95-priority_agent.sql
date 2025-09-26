CREATE TABLE "public"."priority_agent" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "agent_id" text NOT NULL REFERENCES public.agent ON DELETE CASCADE,
    "name" text NOT NULL,
    "config" jsonb NOT NULL DEFAULT '{}' ::jsonb,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone
);

CREATE INDEX idx_agent_priority_id ON "public"."priority_agent" ("priority_id");

ALTER TABLE "public"."priority_agent" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_agent_updated_at
    BEFORE UPDATE ON "public"."priority_agent"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

