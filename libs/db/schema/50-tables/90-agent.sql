CREATE TABLE "public"."agent" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "name" text NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone
);

ALTER TABLE "public"."agent" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_agent_updated_at
    BEFORE UPDATE ON "public"."agent"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();