CREATE TABLE "public"."user" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "clerk_id" text UNIQUE,
    "email" text NOT NULL,
    "name" text,
    "avatar_url" text,
    -- Set when the user requests account deletion (DELETE /account). The
    -- daily purge cron permanently erases the account once this is older
    -- than the 14-day recovery window. Cleared by support to cancel.
    "deletion_requested_at" timestamp with time zone,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT users_email_unique UNIQUE (email)
);

CREATE TRIGGER set_users_updated_at
    BEFORE INSERT OR UPDATE ON "public"."user"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
