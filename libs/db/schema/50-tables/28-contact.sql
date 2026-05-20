CREATE TABLE "public"."contact" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "email" text CHECK (email IS NULL OR email = lower(email)),
    "name" text,
    "avatar_url" text,
    "user_id" uuid REFERENCES "public"."user" ("id") ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
    "primary" boolean NOT NULL DEFAULT false,
    "inviteable" boolean NOT NULL DEFAULT true,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    CONSTRAINT contact_email_unique UNIQUE (email),
    CONSTRAINT contact_primary_requires_user CHECK (NOT "primary" OR user_id IS NOT NULL)
);

CREATE INDEX idx_contact_seq ON "public"."contact" ("seq");

CREATE UNIQUE INDEX contact_user_primary_unique ON contact (user_id) WHERE "primary" = true;

-- Trigram indexes for ILIKE substring search in /sync/threads/search.
CREATE INDEX idx_contact_name_trgm ON "public"."contact" USING gin ("name" extensions.gin_trgm_ops)
WHERE archived_at IS NULL AND name IS NOT NULL;

CREATE INDEX idx_contact_email_trgm ON "public"."contact" USING gin ("email" extensions.gin_trgm_ops)
WHERE archived_at IS NULL AND email IS NOT NULL;

CREATE TRIGGER set_contact_updated_at
    BEFORE INSERT OR UPDATE ON "public"."contact"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_contact_created_at
    BEFORE INSERT ON "public"."contact"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
