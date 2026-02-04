CREATE TABLE "public"."contact" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "email" text NOT NULL CHECK (email = lower(email)),
    "name" text,
    "avatar_url" text,
    "user_id" uuid REFERENCES "auth"."users" ("id") ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
    "primary" boolean NOT NULL DEFAULT false,
    CONSTRAINT contact_email_unique UNIQUE (email),
    CONSTRAINT contact_primary_requires_user CHECK (NOT "primary" OR user_id IS NOT NULL)
);

CREATE UNIQUE INDEX contact_user_primary_unique ON contact (user_id) WHERE "primary" = true;

ALTER TABLE "public"."contact" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_contact_updated_at
    BEFORE INSERT OR UPDATE ON "public"."contact"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_contact_created_at
    BEFORE INSERT ON "public"."contact"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

