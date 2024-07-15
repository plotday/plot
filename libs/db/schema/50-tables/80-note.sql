CREATE TABLE "public"."note" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "context_id" bigint REFERENCES context ON DELETE CASCADE,
    "body" text NOT NULL
);

ALTER TABLE "public"."note" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_note_modified_at
    BEFORE UPDATE ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

