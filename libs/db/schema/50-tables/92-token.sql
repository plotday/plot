CREATE TABLE "public"."token" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "user_id" uuid REFERENCES public."user" ON DELETE CASCADE,
    "publisher_id" bigint REFERENCES "public"."publisher" ON DELETE CASCADE,
    "token" text UNIQUE NOT NULL,
    "name" text,
    "last_used_at" timestamp with time zone,
    CONSTRAINT "token_owner_check" CHECK ((user_id IS NOT NULL)::int + (publisher_id IS NOT NULL)::int = 1)
);

CREATE TRIGGER set_token_updated_at
    BEFORE INSERT OR UPDATE ON "public"."token"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_token_created_at
    BEFORE INSERT ON "public"."token"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

-- Indexes for foreign key performance
CREATE INDEX idx_token_user_id ON "public"."token" (user_id)
WHERE
    archived_at IS NULL;

CREATE INDEX idx_token_publisher_id ON "public"."token" (publisher_id)
WHERE
    archived_at IS NULL;
