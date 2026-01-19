SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.sync_user_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- Get max updated_at from the batch
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to affected priorities (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN user_priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL LOOP
            -- Get previous state
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'activity';
            -- Upsert the sync record
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'activity', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            -- Get the current sync_at after update
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'activity';
            -- Check if we need to notify:
            -- 1. Condition became newly true (wasn't pending before, now is)
            -- 2. OR condition was already true and last_sync_at changed (new update during processing)
            IF (v_prev_update_at IS NULL) OR -- New row, definitely notify
            (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR -- Became pending
        (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) -- Was pending, sync_at changed
    THEN
                v_users_to_notify := array_append(v_users_to_notify, v_user_id);
            END IF;
        END LOOP;
    -- Batch notify all users that need it
    IF array_length(v_users_to_notify, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_user_for_activity_tag ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the parent activity's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
        JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL LOOP
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'activity';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'activity', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'activity';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify := array_append(v_users_to_notify, v_user_id);
            END IF;
        END LOOP;
    IF array_length(v_users_to_notify, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_user_for_contact ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Contact changes affect all users with access to priorities where this contact is linked (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN priority_contact pc ON pc.contact_id = n.id
        JOIN user_priority_expanded upe ON upe.priority_id = pc.priority_id
    WHERE
        upe.archived_at IS NULL
        AND pc.archived_at IS NULL LOOP
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'actor';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'actor', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'actor';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify := array_append(v_users_to_notify, v_user_id);
            END IF;
        END LOOP;
    IF array_length(v_users_to_notify, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_user_for_note ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the parent activity's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
        JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL LOOP
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'note';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'note', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'note';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify := array_append(v_users_to_notify, v_user_id);
            END IF;
        END LOOP;
    IF array_length(v_users_to_notify, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_user_for_note_tag ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the parent note's activity's priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN activity a ON a.id = nt.activity_id
        JOIN user_priority_expanded upe ON upe.priority_id = a.priority_id
    WHERE
        upe.archived_at IS NULL LOOP
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'note';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'note', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'note';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify := array_append(v_users_to_notify, v_user_id);
            END IF;
        END LOOP;
    IF array_length(v_users_to_notify, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_user_for_priority_contact ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify_contact uuid[] := '{}';
    v_users_to_notify_actor uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- priority_contact doesn't have updated_at, use created_at or archived_at
    SELECT
        MAX(GREATEST (created_at, COALESCE(archived_at, created_at))) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN user_priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL LOOP
            -- Handle priority_contact entity
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_contact';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority_contact', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_contact';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify_contact := array_append(v_users_to_notify_contact, v_user_id);
            END IF;
            -- Handle actor entity (priority_contact contributes to actor view)
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'actor';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'actor', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'actor';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify_actor := array_append(v_users_to_notify_actor, v_user_id);
            END IF;
        END LOOP;
    IF array_length(v_users_to_notify_contact, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify_contact);
    END IF;
    IF array_length(v_users_to_notify_actor, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify_actor);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_user_for_priority_twist ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_users_to_notify uuid[] := '{}';
    v_user_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table;
    -- Get all users with access to the priority (including hierarchical access)
    FOR v_user_id IN SELECT DISTINCT
        upe.user_id
    FROM
        new_table n
        JOIN user_priority_expanded upe ON upe.priority_id = n.priority_id
    WHERE
        upe.archived_at IS NULL LOOP
            SELECT
                last_update_at,
                last_sync_at INTO v_prev_update_at,
                v_prev_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_twist';
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'priority_twist', v_max_updated_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            SELECT
                last_sync_at INTO v_current_sync_at
            FROM
                user_sync
            WHERE
                user_id = v_user_id
                AND entity = 'priority_twist';
            IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                v_users_to_notify := array_append(v_users_to_notify, v_user_id);
            END IF;
        END LOOP;
    IF array_length(v_users_to_notify, 1) > 0 THEN
        PERFORM
            call_user_sync_api (v_users_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
