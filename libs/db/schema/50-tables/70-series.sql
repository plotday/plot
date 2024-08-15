CREATE TABLE "public"."series" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    -- matching fields
    "series" text NOT NULL,
    "invitees" text[],
    "embedding" vector (384),
    -- overrides
    "context_id" uuid REFERENCES context ON DELETE SET NULL,
    CONSTRAINT series_unique UNIQUE (user_id, series)
);

ALTER TABLE "public"."series" ENABLE ROW LEVEL SECURITY;

ALTER publication supabase_realtime
    ADD TABLE public.series;

CREATE TRIGGER set_series_modified_at
    BEFORE UPDATE ON "public"."series"
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

