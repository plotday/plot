CREATE TABLE "public"."series" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    -- matching fields
    "series" text NOT NULL,
    "invitees" text[],
    "embedding" vector (384),
    -- overrides
    "priority_id" uuid REFERENCES priority ON DELETE SET NULL,
    CONSTRAINT series_unique UNIQUE (user_id, series)
);

CREATE TRIGGER set_series_updated_at
    BEFORE INSERT OR UPDATE ON "public"."series"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_series_created_at
    BEFORE INSERT ON "public"."series"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

