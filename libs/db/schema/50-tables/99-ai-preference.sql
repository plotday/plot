CREATE TABLE "public"."ai_preference" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid REFERENCES public."user" ON DELETE CASCADE,
    "team_id" bigint REFERENCES public."team" ON DELETE CASCADE,
    "builtin_ai_key_id" bigint REFERENCES public."ai_key" ON DELETE SET NULL,
    "twist_ai_key_id" bigint REFERENCES public."ai_key" ON DELETE SET NULL,
    "twist_ai_disabled" boolean NOT NULL DEFAULT false,
    "builtin_ai_disabled" boolean NOT NULL DEFAULT false,
    CONSTRAINT ai_preference_scope_check CHECK (
        (user_id IS NOT NULL AND team_id IS NULL)
        OR (user_id IS NULL AND team_id IS NOT NULL)
    )
);

CREATE UNIQUE INDEX idx_ai_preference_user ON "public"."ai_preference" ("user_id")
WHERE
    user_id IS NOT NULL;

CREATE UNIQUE INDEX idx_ai_preference_team ON "public"."ai_preference" ("team_id")
WHERE
    team_id IS NOT NULL;

CREATE TRIGGER set_ai_preference_updated_at
    BEFORE INSERT OR UPDATE ON "public"."ai_preference"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
