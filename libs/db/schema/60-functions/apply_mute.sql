-- Apply a "Skip active for threads like this" mute rule for one user.
--
-- 1. Stamps the seed thread as the rule's anchor on the user's
--    thread_priority row (mute_by_thread_id = seed). Does NOT set
--    archived_at — muted threads land in Done, not Archive.
-- 2. Marks the seed as read and inactive in thread_state so it leaves
--    the Doing section and surfaces in Done.
-- 3. Fans out to every candidate returned by find_mute_candidates,
--    repeating both updates per-user.
--
-- Idempotent: re-applying with the same seed re-mutes anything the user
-- has un-muted since (matches the "rule keeps running" semantics).
-- Returns the number of thread_priority rows that newly carry the rule
-- anchor (transitioned from NULL → seed, excluding the seed itself).
CREATE OR REPLACE FUNCTION "user".apply_mute (
    p_user_id uuid,
    p_seed_thread_id uuid
)
    RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_affected integer := 0;
    v_candidate_ids uuid[];
    v_lock_ids uuid[];
BEGIN
    -- Collect candidate ids up front. Materializing them (rather than
    -- streaming the SETOF into the INSERT below) lets us:
    --   1. Pre-lock the parent thread rows in a deterministic order, and
    --   2. Drive the thread_priority upsert from a sortable array.
    SELECT COALESCE(array_agg(cid), ARRAY[]::uuid[])
    INTO v_candidate_ids
    FROM "user".find_mute_candidates(p_user_id, p_seed_thread_id) cid;

    -- Lock every thread we're about to touch — the seed plus the fan-out
    -- candidates — in ascending id order. upsert_thread always locks
    -- thread → thread_priority in that order; taking the locks here in
    -- the same order avoids deadlocks with concurrent upsert_thread.
    SELECT COALESCE(array_agg(DISTINCT id ORDER BY id), ARRAY[]::uuid[])
    INTO v_lock_ids
    FROM unnest(v_candidate_ids || ARRAY[p_seed_thread_id]) AS id
    WHERE id IS NOT NULL;

    IF cardinality(v_lock_ids) > 0 THEN
        PERFORM 1
        FROM public.thread t
        WHERE t.id = ANY(v_lock_ids)
        ORDER BY t.id
        FOR NO KEY UPDATE;
    END IF;

    -- Stamp the seed's thread_priority row. We use ON CONFLICT DO UPDATE
    -- rather than a bare UPDATE so a user who somehow lacks a
    -- thread_priority row for the seed still gets the rule recorded;
    -- that's unusual but cheap to handle.
    INSERT INTO public.thread_priority (
        thread_id, user_id, priority_id, mute_by_thread_id
    )
    VALUES (
        p_seed_thread_id,
        p_user_id,
        "user".root_priority_id(p_user_id),
        p_seed_thread_id
    )
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
    DO UPDATE SET
        mute_by_thread_id = p_seed_thread_id,
        updated_at = now();

    -- Mark the seed read and inactive so it moves to Done immediately.
    INSERT INTO public.thread_state (
        user_id, thread_id, active, read_at
    )
    VALUES (p_user_id, p_seed_thread_id, FALSE, now())
    ON CONFLICT (user_id, thread_id)
    DO UPDATE SET
        active = FALSE,
        read_at = COALESCE(thread_state.read_at, now()),
        updated_at = now();

    -- Fan out to candidates. INSERT then ON CONFLICT update so candidates
    -- without a thread_priority row (rare — typically every visible thread
    -- has one) also pick up the flag. ORDER BY thread_id makes the lock
    -- acquisition on thread_priority deterministic across concurrent
    -- apply_mute calls (same user, different seeds with overlapping
    -- candidates) so they can't deadlock with each other.
    IF cardinality(v_candidate_ids) > 0 THEN
        WITH upserted AS (
            INSERT INTO public.thread_priority (
                thread_id, user_id, priority_id, mute_by_thread_id
            )
            SELECT c.thread_id,
                   p_user_id,
                   "user".root_priority_id(p_user_id),
                   p_seed_thread_id
            FROM unnest(v_candidate_ids) AS c(thread_id)
            ORDER BY c.thread_id
            ON CONFLICT ON CONSTRAINT thread_priority_pkey
            DO UPDATE SET
                mute_by_thread_id = p_seed_thread_id,
                updated_at = now()
            RETURNING thread_id
        )
        SELECT count(*)::int INTO v_affected FROM upserted;

        -- Mark every candidate read and inactive.
        INSERT INTO public.thread_state (user_id, thread_id, active, read_at)
        SELECT p_user_id, c.thread_id, FALSE, now()
        FROM unnest(v_candidate_ids) AS c(thread_id)
        ORDER BY c.thread_id
        ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            active = FALSE,
            read_at = COALESCE(thread_state.read_at, now()),
            updated_at = now();
    END IF;

    RETURN v_affected;
END;
$$;

COMMENT ON FUNCTION "user".apply_mute (uuid, uuid) IS
    'Apply the "Skip active for threads like this" mute rule anchored at p_seed_thread_id for p_user_id. Stamps mute_by_thread_id=seed and marks read+inactive in thread_state for both the seed and every candidate (per find_mute_candidates). Returns affected candidate count.';
