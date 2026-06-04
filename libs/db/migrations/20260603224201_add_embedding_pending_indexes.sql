-- Create index "idx_note_embedding_pending" to table: "note"
CREATE INDEX "idx_note_embedding_pending" ON "public"."note" ("created_at" DESC) WHERE (embedding IS NULL);
-- Create index "idx_thread_embedding_pending" to table: "thread"
CREATE INDEX "idx_thread_embedding_pending" ON "public"."thread" ("created_at" DESC) WHERE (embedding IS NULL);
