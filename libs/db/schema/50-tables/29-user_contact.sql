-- Join table connecting users to contacts with dual semantics:
--
--   linked = true  : this contact IS one of the user's identities
--                    (their work email, personal email, etc.). Used for thread
--                    visibility and count-tag ownership. At most one row per
--                    user may have primary = true.
--   linked = false : this contact is VISIBLE to the user (they can mention it
--                    in the With picker, see it rendered in threads). Created
--                    as contacts show up via the user's connections, threads
--                    they are added to, or teammates in shared teams.
--
-- Replaces the legacy (contact.user_id, contact.primary) columns for identity
-- linking, and handles contact visibility (replacing the removed priority_contact table).
CREATE TABLE "public"."user_contact" (
    "user_id" uuid NOT NULL REFERENCES "public"."user" ("id") ON DELETE CASCADE,
    "contact_id" uuid NOT NULL REFERENCES "public"."contact" ("id") ON DELETE CASCADE,
    "linked" boolean NOT NULL DEFAULT false,
    "primary" boolean NOT NULL DEFAULT false,
    "source" text,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "archived_at" timestamptz,
    PRIMARY KEY ("user_id", "contact_id"),
    CONSTRAINT user_contact_primary_requires_linked CHECK (NOT "primary" OR "linked")
);

CREATE INDEX idx_user_contact_contact_id ON "public"."user_contact" ("contact_id");

CREATE INDEX idx_user_contact_user_id_linked ON "public"."user_contact" ("user_id")
    WHERE "linked" = true AND "archived_at" IS NULL;

CREATE UNIQUE INDEX idx_user_contact_user_primary_unique ON "public"."user_contact" ("user_id")
    WHERE "primary" = true;

CREATE TRIGGER set_user_contact_updated_at
    BEFORE INSERT OR UPDATE ON "public"."user_contact"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_user_contact_created_at
    BEFORE INSERT ON "public"."user_contact"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
