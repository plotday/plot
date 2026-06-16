-- Per-user, per-thread state. Replaces the legacy `thread_unread` table and
-- absorbs the per-user fields that previously lived on `schedule` (`order`,
-- per-user `at`/`on`). The schedule table now holds only shared and
-- link-attached schedules.
--
-- Columns:
--   active — the user is acting on (or about to act on) this thread now.
--     Drives the Doing section of the unified feed and bypasses the
--     "low importance" filter. Set with high confidence by the AI for
--     direct asks; otherwise the user (or a connector like Gmail-star)
--     sets it themselves.
--   urgent — bypasses the per-priority `see_within` delay for push/email.
--     Reserved for time-sensitive material where the user should be notified
--     before the next scheduled response window.
--   importance — 0..100. 0..49 is "low importance" and does NOT trigger
--     proactive notifications or feed surfacing unless `urgent` is also true.
--     The AI scores promotional / unsolicited content < 50.
--   read_at — NULL while the thread is unread; set when the user reads it.
--   bumped_at — manual bump-to-top timestamp.
--   "order" — drag-to-reorder position within the Doing / Scheduled sections.
--   "on" / "at" — per-user "I'll handle this on this date / at this time"
--     intent. Previously on schedule. The shared schedule table still owns
--     event-shaped scheduling (calendar invites, link timing).
CREATE TABLE "public"."thread_state" (
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "thread_id" uuid NOT NULL REFERENCES public.thread ON DELETE CASCADE,
    "active" boolean NOT NULL DEFAULT FALSE,
    "urgent" boolean NOT NULL DEFAULT FALSE,
    "importance" smallint NOT NULL DEFAULT 50 CHECK (importance >= 0 AND importance <= 100),
    "read_at" timestamptz,          -- NULL = unread; set when user reads
    "bumped_at" timestamptz,        -- for manual bumps
    "last_note_source_created_at" timestamptz, -- per-user MAX(source_created_at) over SCOPED visible notes; projected via GREATEST in user.thread (see 25-note.sql scoped branch). NULL for users with no scoped note (shared thread column carries it).
    "order" double precision,       -- drag-to-reorder within Doing / Scheduled
    "on" daterange,                 -- per-user "do on this date"
    "at" tstzrange,                 -- per-user "do at this time"
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    PRIMARY KEY (user_id, thread_id),
    -- Mutually exclusive timing fields; both null is allowed (no timed intent).
    CONSTRAINT thread_state_at_xor_on CHECK (
        ("at" IS NULL OR "on" IS NULL)
    )
);

-- Trigger for updated_at / seq
CREATE TRIGGER set_thread_state_updated_at
    BEFORE INSERT OR UPDATE ON "public"."thread_state"
    FOR EACH ROW EXECUTE FUNCTION update_seq_and_updated_at();

CREATE INDEX idx_thread_state_seq ON "public"."thread_state" ("seq");

-- For unread queries (read_at IS NULL)
CREATE INDEX idx_thread_state_user_unread ON "public"."thread_state" ("user_id", "thread_id", "read_at");

-- For view joins on thread_id
CREATE INDEX idx_thread_state_thread_id ON "public"."thread_state" ("thread_id");

-- For agenda queries that filter by per-user on/at ranges
CREATE INDEX idx_thread_state_on ON "public"."thread_state" USING gist ("on") WHERE "on" IS NOT NULL;
CREATE INDEX idx_thread_state_at ON "public"."thread_state" USING gist ("at") WHERE "at" IS NOT NULL;

-- Partial index for the Doing reorder section query.
CREATE INDEX idx_thread_state_active  ON "public"."thread_state" ("user_id", "order") WHERE active;
