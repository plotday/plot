-- Modify "sync_user_for_schedule" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_schedule" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- For DELETE (transition table values are deleted rows; seq column is NULL
    -- on those handled by trigger functions that fall back to now() above)
    -- and edge-case empty batches, fall back to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Get all users who have the schedule's thread filed via thread_priority
    -- Handles both direct thread_id and link schedules (via link → thread)
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        LEFT JOIN link l ON l.id = n.link_id
        JOIN thread_priority tp ON tp.thread_id = COALESCE(n.thread_id, l.thread_id)
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'schedule', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    -- The thread_priority loop above covers every user who can see the
    -- schedule. Schedules are now purely shared/link-scoped (the per-user
    -- schedule.user_id column was removed when per-user "todo" intent moved
    -- to thread_state), so there are no per-user schedule owners to notify
    -- separately. A leftover loop referencing the dropped schedule.user_id
    -- column here threw "column ... does not exist" on every schedule write.
    RETURN NULL;
END;
$$;
