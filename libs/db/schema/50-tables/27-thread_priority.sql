-- Per-user filing of a thread into the user's priority hierarchy.
--
-- A thread has no single priority_id of its own. Instead every user that
-- can see the thread gets one thread_priority row pointing at the priority
-- they want the thread to appear under.
--
-- For human-authored threads the author gets an explicit row via the
-- upsert_thread RPC. Peer users are filed by the file_thread_priority_peers
-- trigger when a thread lists them in contacts. Priority selection is
-- driven by classify_thread_for_user which scores against the user's
-- explicitly-moved threads (rows where user_moved = TRUE).
CREATE TABLE "public"."thread_priority" (
    "thread_id" uuid NOT NULL REFERENCES public.thread (id) ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" (id) ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority (id) ON DELETE CASCADE,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    -- Per-user archive. A user's connector archive, or an explicit local
    -- archive, sets this without touching thread.archived_at — other users'
    -- access is preserved. The thread is globally archived only when all
    -- thread_priority rows are archived and no active links remain.
    "archived_at" timestamptz,
    -- TRUE when the user has explicitly moved this thread into priority_id.
    -- Used by classify_thread_for_user as the training set for scoring other
    -- threads, and by reclassify_user_threads as a "sticky" guard — rows
    -- with user_moved = TRUE are never overwritten by automatic re-filing.
    "user_moved" boolean NOT NULL DEFAULT FALSE,
    PRIMARY KEY ("thread_id", "user_id")
);

-- Support queries that count active (non-archived) filings, used by the
-- last-holder trigger and the user.thread view.
CREATE INDEX idx_thread_priority_archived
    ON "public"."thread_priority" ("thread_id")
    WHERE archived_at IS NULL;

-- Fast lookup of a user's filings for the new user.thread view.
CREATE INDEX idx_thread_priority_user_priority
    ON "public"."thread_priority" ("user_id", "priority_id");

-- Fast lookup of threads filed under a specific priority (for priority views).
CREATE INDEX idx_thread_priority_priority_id
    ON "public"."thread_priority" ("priority_id");

-- Support incremental sync queries filtering on updated_at.
CREATE INDEX idx_thread_priority_updated_at
    ON "public"."thread_priority" ("updated_at");

-- Fast lookup of the set of explicitly-moved threads per user — the training
-- set consumed by classify_thread_for_user on every classification call.
CREATE INDEX idx_thread_priority_user_moved
    ON "public"."thread_priority" ("user_id")
    WHERE user_moved = TRUE;

CREATE TRIGGER set_thread_priority_updated_at
    BEFORE INSERT OR UPDATE ON "public"."thread_priority"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_thread_priority_created_at
    BEFORE INSERT ON "public"."thread_priority"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

COMMENT ON TABLE "public"."thread_priority" IS 'Per-user filing of a thread into the user''s priority hierarchy. Each user gets one row per visible thread, pointing at their chosen priority.';
