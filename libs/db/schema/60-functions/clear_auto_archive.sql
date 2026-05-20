-- Reverse an "Archive threads like this" rule for one user.
--
-- Finds every thread_priority row for the user that was flagged with the
-- given seed and clears both the archive timestamp and the flag. This is
-- the broom-toggle-off path; a single thread manually un-archived stays
-- handled by the regular un-archive flow (which only touches that row).
--
-- Returns the number of rows the rule had touched.
CREATE OR REPLACE FUNCTION "user".clear_auto_archive (
    p_user_id uuid,
    p_seed_thread_id uuid
)
    RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_affected integer;
BEGIN
    WITH updated AS (
        UPDATE public.thread_priority tp
        SET archived_at = NULL,
            auto_archived_by_thread_id = NULL,
            updated_at = now()
        WHERE tp.user_id = p_user_id
          AND tp.auto_archived_by_thread_id = p_seed_thread_id
        RETURNING tp.thread_id
    )
    SELECT count(*)::int INTO v_affected FROM updated;

    RETURN COALESCE(v_affected, 0);
END;
$$;

COMMENT ON FUNCTION "user".clear_auto_archive (uuid, uuid) IS
    'Reverse the "Archive threads like this" rule anchored at p_seed_thread_id for p_user_id. Clears archived_at and auto_archived_by_thread_id on every thread_priority row that was filed under the seed. Returns affected row count.';
