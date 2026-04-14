CREATE TABLE "public"."secure_option" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "twist_instance_id" uuid NOT NULL REFERENCES public.twist_instance ON DELETE CASCADE,
    "user_id" uuid REFERENCES public."user" ON DELETE CASCADE,
    "key" text NOT NULL,
    "encrypted_value" text NOT NULL,
    "iv" text NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now()
);

-- Shared options: one value per (twist_instance_id, key) when user_id is NULL
CREATE UNIQUE INDEX idx_secure_option_shared
    ON "public"."secure_option" ("twist_instance_id", "key") WHERE "user_id" IS NULL;

-- Per-user options: one value per (twist_instance_id, key, user_id) when user_id is set
CREATE UNIQUE INDEX idx_secure_option_per_user
    ON "public"."secure_option" ("twist_instance_id", "key", "user_id") WHERE "user_id" IS NOT NULL;

CREATE INDEX idx_secure_option_pt ON "public"."secure_option" ("twist_instance_id");

CREATE TRIGGER set_secure_option_updated_at
    BEFORE INSERT OR UPDATE ON "public"."secure_option"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
