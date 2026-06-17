-- Drop index "idx_note_access_groups" from table: "note"
DROP INDEX "public"."idx_note_access_groups";
-- Drop index "idx_note_embedding_pending" from table: "note"
DROP INDEX "public"."idx_note_embedding_pending";
-- Drop index "idx_note_key" from table: "note"
DROP INDEX "public"."idx_note_key";
-- Drop index "note_embedding_idx" from table: "note"
DROP INDEX "public"."note_embedding_idx";
-- Create index "idx_note_embedding_pending" to table: "note"
CREATE INDEX "idx_note_embedding_pending" ON "public"."note" ("created_at" DESC) WHERE ((embedding IS NULL) AND (content IS NOT NULL) AND (draft = false) AND (archived_at IS NULL));
-- Drop index "idx_schedule_on" from table: "schedule"
DROP INDEX "public"."idx_schedule_on";
-- Drop index "idx_thread_embedding_pending" from table: "thread"
DROP INDEX "public"."idx_thread_embedding_pending";
-- Drop index "idx_thread_external_contacts" from table: "thread"
DROP INDEX "public"."idx_thread_external_contacts";
-- Drop index "idx_thread_team_id" from table: "thread"
DROP INDEX "public"."idx_thread_team_id";
-- Create index "idx_thread_embedding_pending" to table: "thread"
CREATE INDEX "idx_thread_embedding_pending" ON "public"."thread" ("created_at" DESC) WHERE ((embedding IS NULL) AND (title IS NOT NULL) AND (archived_at IS NULL));
-- Drop index "idx_thread_priority_updated_at" from table: "thread_priority"
DROP INDEX "public"."idx_thread_priority_updated_at";
-- Drop index "idx_thread_reaction_thread_id" from table: "thread_reaction"
DROP INDEX "public"."idx_thread_reaction_thread_id";
-- Drop index "idx_thread_read_seq" from table: "thread_read"
DROP INDEX "public"."idx_thread_read_seq";
-- Drop index "idx_thread_state_at" from table: "thread_state"
DROP INDEX "public"."idx_thread_state_at";
-- Drop index "idx_thread_state_on" from table: "thread_state"
DROP INDEX "public"."idx_thread_state_on";
