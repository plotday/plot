-- Tracks when users last read each activity
CREATE TABLE "public"."activity_read" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "activity_id" uuid NOT NULL REFERENCES public.activity ON DELETE CASCADE,
    "read_at" timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT activity_read_unique UNIQUE (user_id, activity_id)
);

ALTER TABLE "public"."activity_read" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_activity_read_updated_at
    BEFORE INSERT OR UPDATE ON "public"."activity_read"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER activity_read_insert_api_call
    AFTER INSERT ON "public"."activity_read"
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.notify_internal_api_for_activity_read ();

CREATE TRIGGER activity_read_update_api_call
    AFTER UPDATE ON "public"."activity_read"
    REFERENCING NEW TABLE AS new_rows OLD TABLE AS old_rows
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.notify_internal_api_for_activity_read ();

-- Enhanced composite index supporting read_at comparisons in unread queries
CREATE INDEX idx_activity_read_user_read ON "public"."activity_read" ("user_id", "activity_id", "read_at");

