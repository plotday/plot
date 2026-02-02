-- Tracks when users last read each activity
CREATE TABLE "public"."activity_read" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "activity_id" uuid NOT NULL REFERENCES public.activity ON DELETE CASCADE,
    "read_at" timestamp with time zone NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, activity_id)
);

ALTER TABLE "public"."activity_read" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_activity_read_updated_at
    BEFORE INSERT OR UPDATE ON "public"."activity_read"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

-- Enhanced composite index supporting read_at comparisons in unread queries
CREATE INDEX idx_activity_read_user_read ON "public"."activity_read" ("user_id", "activity_id", "read_at");

-- Index for joins on activity_id alone (PK is user_id, activity_id which doesn't help)
-- Used in user_activity and user_priority_unread views
CREATE INDEX idx_activity_read_activity_id ON "public"."activity_read" ("activity_id");

