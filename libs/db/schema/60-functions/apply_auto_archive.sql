-- Apply an "Archive threads like this" rule for one user.
--
-- 1. Stamps the seed thread as the rule's anchor on the user's
--    thread_priority row (auto_archived_by_thread_id = seed, archived_at = now).
-- 2. Fans out to every candidate returned by find_auto_archive_candidates,
--    setting the same two fields per-user.
--
-- Idempotent: re-applying with the same seed re-archives anything the user
-- has un-archived since (matches the "rule keeps running" semantics).
-- Returns the number of rows that were newly archived (i.e. their
-- thread_priority.archived_at transitioned NULL -> now).
CREATE OR REPLACE FUNCTION "user".apply_auto_archive (
    p_user_id uuid,
    p_seed_thread_id uuid
)
    RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_affected integer := 0;
    v_seed_count integer := 0;
BEGIN
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
    -- has one) also pick up the flag.
    WITH candidates AS (
        SELECT cid AS thread_id
        FROM "user".find_auto_archive_candidates(p_user_id, p_seed_thread_id) cid
    ),
    upserted AS (
        INSERT INTO public.thread_priority (
            thread_id, user_id, priority_id, archived_at, auto_archived_by_thread_id
        )
        SELECT c.thread_id,
               p_user_id,
               "user".root_priority_id(p_user_id),
               now(),
               p_seed_thread_id
        FROM candidates c
        ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET
            archived_at = COALESCE(thread_priority.archived_at, EXCLUDED.archived_at),
            auto_archived_by_thread_id = p_seed_thread_id,
            updated_at = now()
        RETURNING thread_id
    )
    SELECT count(*)::int INTO v_affected FROM upserted;

    RETURN v_affected;
END;
$$;

COMMENT ON FUNCTION "user".apply_auto_archive (uuid, uuid) IS
    'Apply the "Archive threads like this" rule anchored at p_seed_thread_id for p_user_id. Stamps the seed and every candidate (per find_auto_archive_candidates) with archived_at=now() and auto_archived_by_thread_id=seed. Returns affected row count.';
