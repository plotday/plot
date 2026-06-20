-- User sync trigger function for thread changes
CREATE OR REPLACE FUNCTION public.sync_user_for_thread ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    -- Get max updated_at from the batch
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
    -- Get all users who have this thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN thread_priority tp ON tp.thread_id = n.id
    ORDER BY
        tp.user_id LOOP
            -- Upsert the sync record
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for note changes
CREATE OR REPLACE FUNCTION public.sync_user_for_note ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
    -- Get all users who have the note's thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'note', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for priority changes
CREATE OR REPLACE FUNCTION public.sync_user_for_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
    -- Get all users with access to the priority (including hierarchical access via ancestors)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN "user".priority_expanded upe ON upe.priority_id = n.id
    WHERE
        upe.archived_at IS NULL
    ORDER BY
        upe.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'priority', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for session changes
CREATE OR REPLACE FUNCTION public.sync_user_for_session ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
    -- Only notify the session owner
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'session', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for twist_instance changes
CREATE OR REPLACE FUNCTION public.sync_user_for_twist_instance ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
    -- Notify the owner of each twist_instance
    FOR v_user_id IN SELECT DISTINCT
        n.owner_id
    FROM
        new_table n
    ORDER BY
        1 LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'twist_instance', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for thread_priority changes.
-- The user.thread view rolls thread + thread_priority into one row per user,
-- so any thread_priority insert/update/delete changes what that user sees
-- (priority_id, archived_at, user_moved). Bump the affected user's `thread`
-- entity so UserSync broadcasts and the client repulls.
CREATE OR REPLACE FUNCTION public.sync_user_for_thread_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
$function$;

-- User sync trigger function for thread_priority UPDATEs.
--
-- Identical effect to sync_user_for_thread_priority for any update that changes
-- a user-visible column, but QUIET for a classify_at-only write. The classify
-- worker's "same result" settle (SET classify_at = NULL) and the reclassify /
-- channel-default / topic markers (SET classify_at = now()) change only the
-- internal classify_at column, which no user.* view ever surfaces — so they must
-- not bump the per-user singleton user_sync(user_id,'thread') row. Under
-- reclassify churn those no-op writes dominated that singleton's write rate and
-- serialized on its row lock, backing concurrent settles up to the statement
-- timeout (PostHog 019ed55a). Comparing to_jsonb(NEW) vs to_jsonb(OLD) with the
-- internal classify_at / seq / updated_at keys removed is self-maintaining: any
-- column later added to thread_priority is compared by default, so a real change
-- to it still bumps sync (safe direction). seq/updated_at are excluded because
-- the BEFORE-row trigger always rewrites them; classify_at is excluded because
-- it is internal-only.
--
-- Only wired to the UPDATE trigger. INSERT and DELETE keep firing
-- sync_user_for_thread_priority unconditionally — a row appearing or
-- disappearing always changes what the user sees.
CREATE OR REPLACE FUNCTION public.sync_user_for_thread_priority_update ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    -- Watermark over only the rows with a user-visible change.
    SELECT MAX(n.updated_at), MAX(n.seq)
      INTO v_max_updated_at, v_max_seq
      FROM new_table n
      JOIN old_table o ON o.thread_id = n.thread_id AND o.user_id = n.user_id
     WHERE to_jsonb(n) - 'classify_at' - 'seq' - 'updated_at'
           IS DISTINCT FROM to_jsonb(o) - 'classify_at' - 'seq' - 'updated_at';

    -- Nothing view-relevant changed in the whole statement (classify_at-only):
    -- stay quiet, leave the user_sync singleton untouched.
    IF v_max_seq IS NULL THEN
        RETURN NULL;
    END IF;
    IF v_max_updated_at IS NULL THEN
        v_max_updated_at := now();
    END IF;

    -- Skip users that no longer exist (mirrors sync_user_for_thread_priority's
    -- CASCADE-delete guard).
    FOR v_user_id IN SELECT DISTINCT
        n.user_id
    FROM
        new_table n
        JOIN old_table o ON o.thread_id = n.thread_id AND o.user_id = n.user_id
    WHERE
        EXISTS (SELECT 1 FROM "user" u WHERE u.id = n.user_id)
        AND to_jsonb(n) - 'classify_at' - 'seq' - 'updated_at'
            IS DISTINCT FROM to_jsonb(o) - 'classify_at' - 'seq' - 'updated_at'
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
$function$;

-- User sync trigger function for thread_read changes
CREATE OR REPLACE FUNCTION public.sync_user_for_thread_read ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
    -- Only notify the reading user
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread_read', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for thread_state changes.
-- Notifies the affected user so their thread view refreshes with updated state.
CREATE OR REPLACE FUNCTION public.sync_user_for_thread_state ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
    -- Only notify the affected user (the one marked as unread)
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread_read', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for thread_tag changes
CREATE OR REPLACE FUNCTION public.sync_user_for_thread_tag ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
    -- Get all users who have the thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN thread_priority tp ON tp.thread_id = a.id
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for note_tag changes
CREATE OR REPLACE FUNCTION public.sync_user_for_note_tag ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
    -- Get all users who have the note's thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN thread_priority tp ON tp.thread_id = nt.thread_id
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'note', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for contact changes (triggers actor sync)
CREATE OR REPLACE FUNCTION public.sync_user_for_contact ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
    -- Contact changes affect all users who have visibility of this contact via user_contact
    FOR v_user_id IN SELECT DISTINCT
        uc.user_id
    FROM
        new_table n
        JOIN user_contact uc ON uc.contact_id = n.id
    WHERE
        uc.archived_at IS NULL
    ORDER BY
        uc.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'actor', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for channel changes
CREATE OR REPLACE FUNCTION public.sync_user_for_channel ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
    -- Notify the owner of the source account
    FOR v_user_id IN SELECT DISTINCT
        pt.owner_id
    FROM
        new_table n
        JOIN twist_instance pt ON pt.id = n.twist_instance_id
    ORDER BY
        pt.owner_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'channel', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for twist_instance_connection changes
-- When a user connects/disconnects OR a connection's status fields change
-- (needs_reauth_at, initial_sync_started_at, initial_sync_completed_at),
-- notify that user so their user.twist + user.twist_connection data refreshes.
CREATE OR REPLACE FUNCTION public.sync_user_for_twist_instance_connection ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
$function$;

-- User sync trigger function for link changes
CREATE OR REPLACE FUNCTION public.sync_user_for_link ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
    -- Get all users who have the link's thread filed via thread_priority,
    -- or who own the link's direct priority (for threadless links)
    FOR v_user_id IN SELECT DISTINCT
        COALESCE(tp.user_id, p.user_id) AS user_id
    FROM
        new_table n
        LEFT JOIN thread_priority tp ON tp.thread_id = n.thread_id
        LEFT JOIN priority p ON p.id = n.priority_id AND n.thread_id IS NULL
    WHERE
        tp.user_id IS NOT NULL OR p.user_id IS NOT NULL
    ORDER BY
        1 LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'thread', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for schedule changes
CREATE OR REPLACE FUNCTION public.sync_user_for_schedule ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
$function$;

-- User sync trigger function for team_user changes.
-- Notifies the affected user directly (team_user rows are per-user).
-- team_user has no updated_at column so we use now() for last_update_at.
CREATE OR REPLACE FUNCTION public.sync_user_for_team_user ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(seq) INTO v_max_seq
    FROM
        new_table;
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    -- Notify the affected user directly
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'team_user', now(), v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for group changes.
CREATE OR REPLACE FUNCTION public.sync_user_for_group ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
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
    FOR v_user_id IN SELECT DISTINCT
        ug.user_id
    FROM
        new_table n
        JOIN "user"."group" ug ON ug.id = n.id
    ORDER BY
        ug.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'group', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for role changes. Roles are user-scoped (one
-- owner per row via role.user_id), so unlike priorities there is no access
-- graph to walk — mark the owning user dirty for the 'role' entity so their
-- UserSync DO broadcasts a 'role' pull to the user's other devices.
CREATE OR REPLACE FUNCTION public.sync_user_for_role ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_max_seq xid8;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at), MAX(seq) INTO v_max_updated_at, v_max_seq
    FROM
        new_table;
    -- Empty-batch / NULL-seq fallback to the current transaction's xid.
    IF v_max_seq IS NULL THEN
        v_max_seq := pg_current_xact_id();
    END IF;
    FOR v_user_id IN SELECT DISTINCT
        n.user_id
    FROM
        new_table n
    WHERE
        n.user_id IS NOT NULL
    ORDER BY
        n.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at, last_update_seq)
                VALUES (v_user_id, 'role', v_max_updated_at, v_max_seq)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at),
                    last_update_seq = GREATEST (user_sync.last_update_seq, EXCLUDED.last_update_seq);
        END LOOP;
    RETURN NULL;
END;
$function$;
