CREATE TABLE "public"."contact" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "email" text NOT NULL CHECK (is_lower (email)),
    "name" text,
    "avatar_url" text,
    "user_id" uuid REFERENCES "auth"."users" ("id") ON DELETE SET NULL,
    CONSTRAINT contact_user_email_unique UNIQUE (email),
    CONSTRAINT contact_user_id_unique UNIQUE (user_id)
);

ALTER TABLE "public"."contact" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_contact_updated_at
    BEFORE UPDATE ON "public"."contact"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

