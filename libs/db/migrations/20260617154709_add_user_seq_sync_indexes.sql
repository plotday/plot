-- Create index "idx_thread_priority_user_seq" to table: "thread_priority"
CREATE INDEX "idx_thread_priority_user_seq" ON "public"."thread_priority" ("user_id", "seq");
-- Create index "idx_thread_state_user_seq" to table: "thread_state"
CREATE INDEX "idx_thread_state_user_seq" ON "public"."thread_state" ("user_id", "seq");
