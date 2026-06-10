-- Modify "upsert_thread_read" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread_read" ("user_id" uuid, "p_thread_id" uuid, "p_read_at" timestamptz, "p_bumped_at" timestamptz DEFAULT NULL::timestamp with time zone) RETURNS "public"."thread_read" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_row thread_read;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_thread_read.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    INSERT INTO thread_read (user_id, thread_id, read_at, bumped_at)
        VALUES (upsert_thread_read.user_id, p_thread_id, COALESCE(p_read_at, now()), p_bumped_at)
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            read_at = EXCLUDED.read_at,
            bumped_at = CASE WHEN p_bumped_at IS NOT NULL THEN p_bumped_at ELSE thread_read.bumped_at END,
            updated_at = now()
    RETURNING * INTO v_row;

    -- Also clear the per-user thread_state read marker, which is the source
    -- of truth for the `unread` flag on user.thread. The legacy thread_read
    -- table above is retained only to feed twist onThreadRead callbacks
    -- (twist_instance_thread_read); the rename to thread_state migrated the
    -- /sync/thread-unread shim but missed this /sync/thread-read path, so a
    -- passive read (opening a non-active thread) used to update thread_read
    -- alone and never cleared the user's unread state. Routing through
    -- clear_thread_state applies the same race-safe guard (only marks read
    -- when read_at IS NULL and p_read_at is at/after the latest content).
    PERFORM "user".clear_thread_state(
        upsert_thread_read.user_id,
        p_thread_id,
        COALESCE(p_read_at, now()),
        p_bumped_at
    );

    RETURN v_row;
END;
$$;

-- Data repair: reconcile reads that were stranded in the legacy thread_read
-- table back into thread_state. Before this fix, passive reads (POST
-- /sync/thread-read) only wrote thread_read, so any thread_state row seeded
-- read_at=NULL (e.g. onboarding/system threads) stayed unread on every client
-- even after the user read it. Mark such rows read using the legacy read_at,
-- but only when it satisfies the same race-safe guard clear_thread_state
-- applies — read_at at/after the thread's latest content — so threads with
-- newer unread content are left unread. The UPDATE bumps thread_state.seq via
-- the set_thread_state_updated_at trigger, so clients re-pull and clear the
-- stale unread indicator.
UPDATE public.thread_state ts
SET read_at = tr.read_at,
    updated_at = now()
FROM public.thread_read tr,
     public.thread t
WHERE tr.user_id = ts.user_id
  AND tr.thread_id = ts.thread_id
  AND t.id = ts.thread_id
  AND ts.read_at IS NULL
  AND tr.read_at IS NOT NULL
  AND tr.read_at >= date_trunc('milliseconds', COALESCE(t.last_note_source_created_at, t.created_at));
