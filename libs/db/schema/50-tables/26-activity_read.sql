-- Tracks when users last read each activity thread
CREATE TABLE "public"."activity_read" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "activity_path" ltree NOT NULL,
    "read_at" timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT activity_read_unique UNIQUE (user_id, activity_path),
    CONSTRAINT activity_read_single_level CHECK (nlevel (activity_path) = 1)
);

ALTER TABLE "public"."activity_read" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_activity_read_updated_at
    BEFORE UPDATE ON "public"."activity_read"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE INDEX idx_activity_read_user_path ON "public"."activity_read" ("user_id", "activity_path");

