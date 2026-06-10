-- Merge one focus into another for a single user: re-file every
-- thread_priority row filed under the source onto the target in one
-- statement, then archive the source focus.
--
-- This replaces the client-side per-thread re-file loop. That loop synced N
-- individual thread saves, and the API treated each one as a first-time
-- explicit filing (user_moved flip + retroactive mark_reclassify_candidates
-- sweep), so merging a focus mass-reclassified the user's workspace — see
-- the June 2026 incident notes on mark_reclassify_candidates. The direct
-- UPDATE deliberately:
--   • does NOT touch user_moved — a bulk merge is a deliberate re-file,
--     not N classifier-training events;
--   • does NOT touch classify_at — rows pending re-classification stay
--     pending and will settle against the moved filing;
--   • relies on the set_thread_priority_updated_at trigger to bump
--     seq/updated_at, so re-filed rows reach clients via the normal
--     /sync/threads cursor.
--
-- Filing is per-user (priority.user_id), so only the calling user's rows
-- move and only their copy of the source focus is archived; teammates are
-- unaffected. Matches the old client loop's scope: threads only — links and
-- schedules filed under the source are not re-pointed (they follow their
-- thread).
--
-- Returns the number of thread filings moved.
CREATE OR REPLACE FUNCTION "user".merge_priority (
    user_id uuid,
    p_source_priority_id uuid,
    p_target_priority_id uuid
)
    RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO 'public', 'user'
    AS $function$
#variable_conflict use_column
DECLARE
    v_moved integer;
BEGIN
    IF p_source_priority_id = p_target_priority_id THEN
        RAISE EXCEPTION 'Cannot merge a focus into itself';
    END IF;

    -- Ownership checks: both focuses must belong to the calling user.
    IF NOT EXISTS (
        SELECT 1 FROM priority p
        WHERE p.id = p_source_priority_id
          AND p.user_id = merge_priority.user_id
    ) THEN
        RAISE EXCEPTION 'Source focus not found';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM priority p
        WHERE p.id = p_target_priority_id
          AND p.user_id = merge_priority.user_id
          AND p.archived_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Target focus not found or archived';
    END IF;

    -- Re-file before archiving the source so no row ever observes an
    -- archived filing (effective_priority_id would bounce it to root).
    UPDATE thread_priority tp
    SET priority_id = p_target_priority_id
    WHERE tp.user_id = merge_priority.user_id
      AND tp.priority_id = p_source_priority_id;
    GET DIAGNOSTICS v_moved = ROW_COUNT;

    UPDATE priority p
    SET archived_at = now()
    WHERE p.id = p_source_priority_id
      AND p.user_id = merge_priority.user_id
      AND p.archived_at IS NULL;

    RETURN v_moved;
END;
$function$;

COMMENT ON FUNCTION "user".merge_priority IS 'Re-file all of one user''s thread filings from a source focus onto a target in a single statement, then archive the source. Replaces the client-side per-thread merge loop so a bulk merge generates no classifier-training signals and no retroactive reclassify sweeps.';
