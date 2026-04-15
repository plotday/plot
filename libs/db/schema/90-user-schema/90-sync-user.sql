-- User sync trigger function for thread changes
CREATE OR REPLACE FUNCTION public.sync_user_for_thread ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    -- Get max updated_at from the batch
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users who have this thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN thread_priority tp ON tp.thread_id = n.id
    ORDER BY
        tp.user_id LOOP
            -- Upsert the sync record
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
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
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users who have the note's thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN thread_priority tp ON tp.thread_id = n.thread_id
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'note', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
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
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
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
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
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
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Only notify the session owner
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'session', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
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
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Notify the owner of each twist_instance
    FOR v_user_id IN SELECT DISTINCT
        n.owner_id
    FROM
        new_table n
    ORDER BY
        1 LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'twist_instance', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
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
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Only notify the reading user
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread_read', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for thread_unread changes
-- Notifies the affected user so their thread view refreshes with updated unread status
CREATE OR REPLACE FUNCTION public.sync_user_for_thread_unread ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Only notify the affected user (the one marked as unread)
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread_read', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
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
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users who have the thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN thread a ON a.id = n.thread_id
        JOIN thread_priority tp ON tp.thread_id = a.id
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
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
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users who have the note's thread filed via thread_priority
    FOR v_user_id IN SELECT DISTINCT
        tp.user_id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN thread_priority tp ON tp.thread_id = nt.thread_id
    ORDER BY
        tp.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'note', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
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
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
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
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'actor', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
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
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Notify the owner of the source account
    FOR v_user_id IN SELECT DISTINCT
        pt.owner_id
    FROM
        new_table n
        JOIN twist_instance pt ON pt.id = n.twist_instance_id
    ORDER BY
        pt.owner_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'channel', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for twist_instance_connection changes
-- When a user connects/disconnects, notify that user so their twist_instance data refreshes
CREATE OR REPLACE FUNCTION public.sync_user_for_twist_instance_connection ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_connected_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(connected_at) INTO v_max_connected_at
    FROM
        new_table;
    -- Notify each affected user directly
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'twist_instance', v_max_connected_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
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
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
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
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'thread', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
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
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
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
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'schedule', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    -- Also notify per-user schedule owners directly
    FOR v_user_id IN SELECT DISTINCT
        n.user_id
    FROM
        new_table n
    WHERE
        n.user_id IS NOT NULL
    ORDER BY
        n.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'schedule', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$function$;

-- User sync trigger function for topic changes.
CREATE OR REPLACE FUNCTION public.sync_user_for_topic ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    FOR v_user_id IN SELECT DISTINCT
        ut.user_id
    FROM
        new_table n
        JOIN "user"."topic" ut ON ut.id = n.id
    ORDER BY
        ut.user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'topic', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$function$;
