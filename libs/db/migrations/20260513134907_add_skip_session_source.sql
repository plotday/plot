-- Drop index "idx_session_schedule_occurrence" from table: "session"
DROP INDEX "public"."idx_session_schedule_occurrence";
-- Modify "session" table
ALTER TABLE "public"."session" DROP CONSTRAINT "session_source_check", ADD CONSTRAINT "session_source_check" CHECK (source = ANY (ARRAY['active'::text, 'event'::text, 'manual'::text, 'skip'::text]));
-- Create index "idx_session_schedule_occurrence" to table: "session"
CREATE UNIQUE INDEX "idx_session_schedule_occurrence" ON "public"."session" ("user_id", "schedule_id", "occurrence_at") WHERE ((schedule_id IS NOT NULL) AND (archived_at IS NULL) AND (source = 'event'::text));
