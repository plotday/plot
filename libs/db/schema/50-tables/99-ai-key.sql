CREATE TABLE "public"."ai_key" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid REFERENCES public."user" ON DELETE CASCADE,
    "organization_id" bigint REFERENCES public."organization" ON DELETE CASCADE,
    "provider" ai_provider NOT NULL,
    "encrypted_key" text NOT NULL,
    "key_suffix" text NOT NULL,
    "iv" text NOT NULL,
    CONSTRAINT ai_key_scope_check CHECK (
        (user_id IS NOT NULL AND organization_id IS NULL)
        OR (user_id IS NULL AND organization_id IS NOT NULL)
    )
);

CREATE UNIQUE INDEX idx_ai_key_user_provider ON "public"."ai_key" ("user_id", "provider")
WHERE
    user_id IS NOT NULL;

CREATE UNIQUE INDEX idx_ai_key_org_provider ON "public"."ai_key" ("organization_id", "provider")
WHERE
    organization_id IS NOT NULL;

CREATE INDEX idx_ai_key_user_id ON "public"."ai_key" ("user_id")
WHERE
    user_id IS NOT NULL;

CREATE INDEX idx_ai_key_org_id ON "public"."ai_key" ("organization_id")
WHERE
    organization_id IS NOT NULL;

CREATE TRIGGER set_ai_key_updated_at
    BEFORE INSERT OR UPDATE ON "public"."ai_key"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
