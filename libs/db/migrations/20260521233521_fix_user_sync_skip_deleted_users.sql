-- Modify "sync_user_for_thread_priority" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_thread_priority" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
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
    -- Fall back to now() for DELETE (which has no updated_at column).
    IF v_max_updated_at IS NULL THEN
        v_max_updated_at := now();
    END IF;
    -- Skip users that no longer exist. When `user` is deleted, CASCADE deletes
    -- `thread_priority` rows in the same transaction; this DELETE trigger then
    -- fires and would otherwise INSERT INTO user_sync for the just-deleted
    -- user_id, violating user_sync_user_id_fkey.
    FOR v_user_id IN SELECT DISTINCT
        n.user_id
    FROM
        new_table n
    WHERE
        EXISTS (SELECT 1 FROM "user" u WHERE u.id = n.user_id)
    ORDER BY
        n.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Modify "sync_user_for_twist_instance_connection" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_twist_instance_connection" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    -- Use the most recent lifecycle stamp on each row -- this matches the
    -- `updated_at` projected by the user.twist_connection view so client
    -- incremental cursors line up.
    SELECT
        MAX(GREATEST(
            connected_at,
            needs_reauth_at,
            initial_sync_started_at,
            initial_sync_completed_at
        )),
        MAX(seq)
    INTO v_max_at, v_max_seq
    FROM
        new_table;
    -- Fall back to now() for DELETE (transition table values are deleted rows).
    IF v_max_at IS NULL THEN
        v_max_at := now();
    END IF;
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Notify each affected user directly. Bump both `twist_instance` (legacy
    -- consumer; user.twist surfaces user_connected) and `twist_connection`
    -- (new entity for needs_reauth / initial_syncing signals).
    --
    -- Skip users that no longer exist. When `user` is deleted, CASCADE deletes
    -- `twist_instance_connection` rows in the same transaction; this DELETE
    -- trigger then fires and would otherwise INSERT INTO user_sync for the
    -- just-deleted user_id, violating user_sync_user_id_fkey.
    FOR v_user_id IN SELECT DISTINCT
        n.user_id
    FROM
        new_table n
    WHERE
        EXISTS (SELECT 1 FROM "user" u WHERE u.id = n.user_id)
    ORDER BY
        n.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'twist_instance', v_max_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'twist_connection', v_max_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$$;
