-- Modify "user_settings" table
ALTER TABLE "public"."user_settings" ADD COLUMN "event_sessions_finalized_through" timestamptz NULL;
-- Create index "idx_user_settings_event_finalize_backfill" to table: "user_settings"
CREATE INDEX "idx_user_settings_event_finalize_backfill" ON "public"."user_settings" ("user_id") WHERE (event_sessions_finalized_through IS NULL);
