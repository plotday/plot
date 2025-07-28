CREATE TABLE "public"."agent" (
    "id" text PRIMARY KEY,
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

CREATE TRIGGER set_agent_updated_at
    BEFORE UPDATE ON "public"."agent"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();


