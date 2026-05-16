-- Create index "idx_session_user_seq" to table: "session"
CREATE INDEX "idx_session_user_seq" ON "public"."session" ("user_id", "seq", "id");
