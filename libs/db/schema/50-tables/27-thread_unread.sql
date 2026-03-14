CREATE TABLE "public"."thread_unread" (
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "thread_id" uuid NOT NULL REFERENCES public.thread ON DELETE CASCADE,
    "urgency" text NOT NULL CHECK (urgency IN ('interrupt', 'inform-requests', 'inform-updates', 'passive')),
    "importance" smallint NOT NULL DEFAULT 50 CHECK (importance >= 0 AND importance <= 100),
    "read_at" timestamptz,          -- NULL = unread; set when user reads
    "bumped_at" timestamptz,        -- for manual bumps
    PRIMARY KEY (user_id, thread_id)
);

-- Trigger for updated_at
CREATE TRIGGER set_thread_unread_updated_at
    BEFORE INSERT OR UPDATE ON "public"."thread_unread"
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- For unread queries (read_at IS NULL)
CREATE INDEX idx_thread_unread_user_unread ON "public"."thread_unread" ("user_id", "thread_id", "read_at");

-- For view joins on thread_id
CREATE INDEX idx_thread_unread_thread_id ON "public"."thread_unread" ("thread_id");
