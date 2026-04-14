CREATE TABLE "public"."ai_key" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid REFERENCES public."user" ON DELETE CASCADE,
    "team_id" bigint REFERENCES public."team" ON DELETE CASCADE,
    "provider" ai_provider NOT NULL,
    "name" text,
    "encrypted_key" text NOT NULL,
    "key_suffix" text NOT NULL,
    "iv" text NOT NULL,
    "custom_base_url" text,
    "fast_model" text,
    "thinking_model" text,
    CONSTRAINT ai_key_scope_check CHECK (
        (user_id IS NOT NULL AND team_id IS NULL)
        OR (user_id IS NULL AND team_id IS NOT NULL)
    )
);

-- One of each standard provider per user
CREATE UNIQUE INDEX idx_ai_key_user_standard ON "public"."ai_key" ("user_id", "provider")
WHERE
    user_id IS NOT NULL AND provider != 'custom';

-- Unique custom provider names per user
CREATE UNIQUE INDEX idx_ai_key_user_custom ON "public"."ai_key" ("user_id", "name")
WHERE
    user_id IS NOT NULL AND provider = 'custom';

-- One of each standard provider per team
CREATE UNIQUE INDEX idx_ai_key_team_standard ON "public"."ai_key" ("team_id", "provider")
WHERE
    team_id IS NOT NULL AND provider != 'custom';

-- Unique custom provider names per team
CREATE UNIQUE INDEX idx_ai_key_team_custom ON "public"."ai_key" ("team_id", "name")
WHERE
    team_id IS NOT NULL AND provider = 'custom';

CREATE INDEX idx_ai_key_user_id ON "public"."ai_key" ("user_id")
WHERE
    user_id IS NOT NULL;

CREATE INDEX idx_ai_key_team_id ON "public"."ai_key" ("team_id")
WHERE
    team_id IS NOT NULL;

CREATE TRIGGER set_ai_key_updated_at
    BEFORE INSERT OR UPDATE ON "public"."ai_key"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
