-- Modify "apply_auto_archive" function
CREATE OR REPLACE FUNCTION "user"."apply_auto_archive" ("p_user_id" uuid, "p_seed_thread_id" uuid) RETURNS integer LANGUAGE plpgsql AS $$
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
    FROM "user".find_auto_archive_candidates(p_user_id, p_seed_thread_id) cid;

    -- Lock every thread we're about to touch — the seed plus the fan-out
    -- candidates — in ascending id order. upsert_thread always locks
    -- thread → thread_priority in that order, and the
    -- maybe_archive_thread_last_holder trigger below will try to upgrade
    -- to a thread lock once each thread_priority row flips to archived.
    -- Without this pre-lock the trigger reverses the order (thread_priority
    -- before thread), so concurrent upsert_thread + apply_auto_archive on
    -- an overlapping thread can deadlock. Taking the locks here, in the
    -- same order upsert_thread uses, removes the cycle. Locking the seed
    -- in the same statement keeps the order single-pass.
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

    -- Stamp the seed row. We use ON CONFLICT DO UPDATE rather than a bare
    -- UPDATE so a user who somehow lacks a thread_priority row for the seed
    -- still gets the rule recorded; that's unusual but cheap to handle.
    --
    -- A bare INSERT with no priority_id would violate
    -- thread_priority_state_valid (priority_id IS NOT NULL OR
    -- classify_at IS NOT NULL), so we fall back to root_priority_id.
    INSERT INTO public.thread_priority (
        thread_id, user_id, priority_id, archived_at, auto_archived_by_thread_id
    )
    VALUES (
        p_seed_thread_id,
        p_user_id,
        "user".root_priority_id(p_user_id),
        now(),
        p_seed_thread_id
    )
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
    DO UPDATE SET
        archived_at = COALESCE(thread_priority.archived_at, EXCLUDED.archived_at),
        auto_archived_by_thread_id = p_seed_thread_id,
        updated_at = now();

    -- Fan out to candidates. We INSERT then ON CONFLICT update so candidates
    -- without a thread_priority row (rare — typically every visible thread
    -- has one) also pick up the flag. ORDER BY thread_id makes the lock
    -- acquisition on thread_priority deterministic across concurrent
    -- apply_auto_archive calls (same user, different seeds with overlapping
    -- candidates) so they can't deadlock with each other.
    IF cardinality(v_candidate_ids) > 0 THEN
        WITH upserted AS (
            INSERT INTO public.thread_priority (
                thread_id, user_id, priority_id, archived_at, auto_archived_by_thread_id
            )
            SELECT c.thread_id,
                   p_user_id,
                   "user".root_priority_id(p_user_id),
                   now(),
                   p_seed_thread_id
            FROM unnest(v_candidate_ids) AS c(thread_id)
            ORDER BY c.thread_id
            ON CONFLICT ON CONSTRAINT thread_priority_pkey
            DO UPDATE SET
                archived_at = COALESCE(thread_priority.archived_at, EXCLUDED.archived_at),
                auto_archived_by_thread_id = p_seed_thread_id,
                updated_at = now()
            RETURNING thread_id
        )
        SELECT count(*)::int INTO v_affected FROM upserted;
    END IF;

    RETURN v_affected;
END;
$$;
-- Modify "clear_auto_archive" function
CREATE OR REPLACE FUNCTION "user"."clear_auto_archive" ("p_user_id" uuid, "p_seed_thread_id" uuid) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_affected integer;
    v_target_ids uuid[];
BEGIN
    -- Materialize the target thread ids first so we can lock the parent
    -- thread rows in deterministic order (matching upsert_thread's
    -- thread → thread_priority order). Concurrent upsert_thread on one
    -- of the target threads would otherwise see clear_auto_archive lock
    -- thread_priority first; an AFTER UPDATE trigger could then need the
    -- thread row already held by the other transaction and deadlock.
    SELECT COALESCE(array_agg(tp.thread_id ORDER BY tp.thread_id), ARRAY[]::uuid[])
    INTO v_target_ids
    FROM public.thread_priority tp
    WHERE tp.user_id = p_user_id
      AND tp.auto_archived_by_thread_id = p_seed_thread_id;

    IF cardinality(v_target_ids) = 0 THEN
        RETURN 0;
    END IF;

    PERFORM 1
    FROM public.thread t
    WHERE t.id = ANY(v_target_ids)
    ORDER BY t.id
    FOR NO KEY UPDATE;

    WITH updated AS (
        UPDATE public.thread_priority tp
        SET archived_at = NULL,
            auto_archived_by_thread_id = NULL,
            updated_at = now()
        WHERE tp.user_id = p_user_id
          AND tp.thread_id = ANY(v_target_ids)
        RETURNING tp.thread_id
    )
    SELECT count(*)::int INTO v_affected FROM updated;

    RETURN COALESCE(v_affected, 0);
END;
$$;
