-- Tracks when users last read each thread
CREATE TABLE "public"."thread_read" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "thread_id" uuid NOT NULL REFERENCES public.thread ON DELETE CASCADE,
    "read_at" timestamp with time zone NOT NULL DEFAULT now(),
    "bumped_at" timestamp with time zone,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    PRIMARY KEY (user_id, thread_id)
);

CREATE TRIGGER set_thread_read_updated_at
    BEFORE INSERT OR UPDATE ON "public"."thread_read"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE INDEX idx_thread_read_seq ON "public"."thread_read" ("seq");

-- Enhanced composite index supporting read_at comparisons in unread queries
CREATE INDEX idx_thread_read_user_read ON "public"."thread_read" ("user_id", "thread_id", "read_at");

-- Index for joins on thread_id alone (PK is user_id, thread_id which doesn't help)
-- Used in user_thread and user_priority_unread views
CREATE INDEX idx_thread_read_thread_id ON "public"."thread_read" ("thread_id");
