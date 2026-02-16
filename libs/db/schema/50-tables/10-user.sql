CREATE TABLE "public"."user" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "clerk_id" text UNIQUE,
    "email" text NOT NULL,
    "name" text,
    "avatar_url" text,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT users_email_unique UNIQUE (email)
);

CREATE TRIGGER set_users_updated_at
    BEFORE INSERT OR UPDATE ON "public"."user"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
