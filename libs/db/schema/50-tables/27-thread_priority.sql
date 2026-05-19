-- Per-user filing of a thread into the user's priority hierarchy.
--
-- A thread has no single priority_id of its own. Instead every user that
-- can see the thread gets one thread_priority row pointing at the priority
-- they want the thread to appear under.
--
-- For human-authored threads the author gets an explicit row via the
-- upsert_thread RPC with the resolved priority. Peer users are filed by
-- the file_thread_priority_peers trigger; the trigger writes a pending
-- marker (priority_id NULL, classify_at = now()) and the consumer Worker
-- (workers/classify) runs the LLM-aware classifier and updates the row.
--
-- See docs/superpowers/specs/2026-05-18-hybrid-classifier-production-wiring-design.md.
CREATE TABLE "public"."thread_priority" (
    "thread_id" uuid NOT NULL REFERENCES public.thread (id) ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" (id) ON DELETE CASCADE,
    -- Settled priority filing. NULL marks the row as pending classification.
    -- Views must use COALESCE(priority_id, root_priority_id(user_id)) gated
    -- by (priority_id IS NOT NULL OR classify_at < now() - classify_visibility_window()).
    "priority_id" uuid REFERENCES public.priority (id) ON DELETE CASCADE,
    -- Pending-classification marker. NOT NULL means the consumer Worker
    -- must (re-)classify this row. NULL means the placement is settled.
    -- See classify_visibility_window() for the view-fallback timing.
    "classify_at" timestamptz,
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
    -- Non-null marks a row that was placed by this channel's current
    -- default_priority_id. Consulted by apply_channel_default to find rows
    -- eligible for re-file when the channel default changes. Cleared when
    -- the user explicitly moves the thread, or when classify no longer
    -- yields the channel default for this row.
    --
    -- Weak reference to channel.id (no FK, since channel is defined after
    -- thread_priority in schema order). A channel delete cascades via
    -- twist_instance → thread → thread_priority anyway, so a stale marker
    -- is unreachable in practice.
    "applied_default_channel_id" bigint,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    PRIMARY KEY ("thread_id", "user_id"),
    -- Both NULL is unrecoverable: the row would be invisible to user
    -- views (no priority_id) and invisible to the sweep (no classify_at).
    CONSTRAINT thread_priority_state_valid
        CHECK (priority_id IS NOT NULL OR classify_at IS NOT NULL)
);

-- Pending-classification index: feeds the recovery sweep query
--   WHERE classify_at < now() - interval '1 hour'
-- and the per-thread dispatch query
--   WHERE classify_at IS NOT NULL.
CREATE INDEX thread_priority_classify_pending_idx
    ON "public"."thread_priority" ("classify_at")
    WHERE classify_at IS NOT NULL;

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

CREATE INDEX idx_thread_priority_seq
    ON "public"."thread_priority" ("seq");

-- Fast lookup of the set of explicitly-moved threads per user — the training
-- set consumed by classify_thread_for_user on every classification call.
CREATE INDEX idx_thread_priority_user_moved
    ON "public"."thread_priority" ("user_id")
    WHERE user_moved = TRUE;

-- Fast lookup of default-placed rows for a given channel, consumed by
-- apply_channel_default when a channel's default_priority_id changes.
CREATE INDEX idx_thread_priority_applied_default
    ON "public"."thread_priority" ("applied_default_channel_id")
    WHERE applied_default_channel_id IS NOT NULL;

CREATE TRIGGER set_thread_priority_updated_at
    BEFORE INSERT OR UPDATE ON "public"."thread_priority"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_thread_priority_created_at
    BEFORE INSERT ON "public"."thread_priority"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

COMMENT ON TABLE "public"."thread_priority" IS 'Per-user filing of a thread into the user''s priority hierarchy. Each user gets one row per visible thread, pointing at their chosen priority.';
COMMENT ON COLUMN "public"."thread_priority"."priority_id" IS 'User''s priority filing. NULL means classification is pending (see classify_at). Views must use COALESCE(priority_id, root_priority_id(user_id)) gated by the visibility filter (priority_id IS NOT NULL OR classify_at < now() - classify_visibility_window()).';
COMMENT ON COLUMN "public"."thread_priority"."classify_at" IS 'Timestamp when classification was last requested. NULL once classification has succeeded. NOT NULL signals the consumer Worker (workers/classify) to (re-)classify this row.';
