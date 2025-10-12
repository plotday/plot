CREATE TABLE "public"."token" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "user_id" uuid REFERENCES auth.users ON DELETE CASCADE,
    "publisher_id" bigint REFERENCES "public"."publisher" ON DELETE CASCADE,
    "token" text UNIQUE NOT NULL,
    "name" text,
    "last_used_at" timestamp with time zone,
    CONSTRAINT "token_owner_check" CHECK ((user_id IS NOT NULL)::int + (publisher_id IS NOT NULL)::int = 1)
);

ALTER TABLE "public"."token" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_token_updated_at
    BEFORE UPDATE ON "public"."token"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

-- RLS policies: Users can manage their own tokens
CREATE POLICY "Users can view their own tokens" ON "public"."token"
    FOR SELECT
    USING (auth.uid () = user_id);

CREATE POLICY "Users can create their own tokens" ON "public"."token"
    FOR INSERT
    WITH CHECK (auth.uid () = user_id);

CREATE POLICY "Users can delete their own tokens" ON "public"."token"
    FOR DELETE
    USING (auth.uid () = user_id);

CREATE POLICY "Users can update their own tokens" ON "public"."token"
    FOR UPDATE
    USING (auth.uid () = user_id)
    WITH CHECK (auth.uid () = user_id);
