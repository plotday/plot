-- Negative categorization signals: "this thread does NOT belong in this
-- priority/focus". Two sources:
--   'moved_out'   — the user explicitly moved a thread out of a focus
--                   (captured client-side, which knows the source focus
--                   reliably; see POST /sync/priorities/negatives).
--   'deselected'  — a candidate the matcher proposed for a focus that the
--                   user deselected during two-step focus creation.
--
-- Consumed by the classifier (libs/classifier ts-hybrid-scoring +
-- classify_thread_for_user) as a down-weight on the embedding similarity to
-- a focus, the mirror image of the user_moved positive training set.
--
-- This table is NOT read by any user.* view, so it is never synced to
-- clients — a bare DELETE here is safe.
CREATE TABLE "public"."thread_priority_negative" (
    "user_id" uuid NOT NULL REFERENCES public."user" (id) ON DELETE CASCADE,
    "thread_id" uuid NOT NULL REFERENCES public.thread (id) ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority (id) ON DELETE CASCADE,
    "source" text NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, thread_id, priority_id)
);

-- Look up all negative examples for a priority (classifier down-weight).
CREATE INDEX idx_thread_priority_negative_user_priority
    ON "public"."thread_priority_negative" ("user_id", "priority_id");
