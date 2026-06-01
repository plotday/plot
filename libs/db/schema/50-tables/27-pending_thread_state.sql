-- Deferred thread_state pushes that arrived before the user's
-- thread_priority row landed.
--
-- The Flutter client creates a new Tag.todo thread by firing three
-- independent /sync/* pushes in close succession (threads, notes,
-- thread-state). In Cloudflare Workers these are independent invocations
-- and the thread-state push frequently reaches the server before the
-- threads push has committed. The legacy upsert_thread_state raised
-- 'Thread not found' in that window, the route caught it via mapPgError,
-- the failure surfaced as `{ok: true, failed: [...]}` which the client
-- ignores, and the user's task silently dropped out of the Active feed.
--
-- The fix: stash the full upsert_thread_state payload here keyed on
-- (user_id, thread_id) and apply it as soon as a usable thread_priority
-- row appears (see apply_pending_thread_state in 95-triggers/).
--
-- Intentionally NOT exposed via any user.* view. This is server-side
-- bookkeeping only; the eventual apply produces a thread_state row that
-- syncs to clients normally.
--
-- No foreign keys: a pending row should outlive the (yet-to-arrive)
-- thread, and if the thread/user is ultimately deleted, the orphaned row
-- is harmless until a periodic sweep collects it.
CREATE TABLE "public"."pending_thread_state" (
    "user_id" uuid NOT NULL,
    "thread_id" uuid NOT NULL,
    -- Serialized upsert_thread_state parameters: every p_* arg the
    -- function takes, mapped one-to-one (p_active, p_set_active, p_on,
    -- p_at, p_order, p_importance, ...). The applier deserializes each
    -- arg with the same default it would get from a fresh call.
    "payload" jsonb NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("user_id", "thread_id")
);

COMMENT ON TABLE "public"."pending_thread_state" IS 'Deferred upsert_thread_state payloads waiting for a usable thread_priority row to appear. Flushed by the apply_pending_thread_state trigger on thread_priority insert/update.';
