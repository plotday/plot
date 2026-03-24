CREATE TABLE "public"."secure_option" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "priority_twist_id" uuid NOT NULL REFERENCES public.priority_twist ON DELETE CASCADE,
    "key" text NOT NULL,
    "encrypted_value" text NOT NULL,
    "iv" text NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    UNIQUE ("priority_twist_id", "key")
);

CREATE INDEX idx_secure_option_pt ON "public"."secure_option" ("priority_twist_id");

CREATE TRIGGER set_secure_option_updated_at
    BEFORE INSERT OR UPDATE ON "public"."secure_option"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
