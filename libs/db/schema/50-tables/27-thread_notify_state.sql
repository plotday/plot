-- Per-(user, thread) notification high-water mark: the thread_state.updated_at
-- value the user was last *notified* about (push wake / local notification
-- content). The notify-candidate queries (workers/api notification-content.ts
-- and push-notify.ts) suppress a thread when its thread_state.updated_at has
-- not advanced past this mark.
--
-- Why this exists: notification re-notify suppression otherwise lives only on
-- the first-level focus (priority.notification_cleared_at). That per-focus
-- high-water mark does NOT follow a thread when the user moves it to another
-- focus, so an already-notified, still-unread thread re-filed under an
-- uncleared focus would notify a second time (the same email re-announced in
-- the new focus). This mark is keyed on the thread, so it follows the thread
-- across focus moves. A genuine new reply bumps thread_state.updated_at past
-- the mark and correctly re-notifies; a pure move does not (a move touches
-- thread_priority, not thread_state), so it stays suppressed.
--
-- Why a separate table and not a thread_state column: thread_state's
-- BEFORE INSERT OR UPDATE trigger (set_thread_state_updated_at) rewrites
-- updated_at and seq on every write. Stamping the mark on thread_state would
-- bump the very timestamp the suppression compares against, and would churn
-- the synced thread_state row out to every one of the user's devices. Keeping
-- the mark here decouples it from that trigger.
--
-- Not synced — no user.* view reads this table; it is pure server-side
-- notification bookkeeping (cf. classification_decision).
CREATE TABLE "public"."thread_notify_state" (
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "thread_id" uuid NOT NULL REFERENCES public.thread ON DELETE CASCADE,
    -- Highest thread_state.updated_at the user has been notified about.
    "notified_at" timestamptz NOT NULL,
    PRIMARY KEY (user_id, thread_id)
);
