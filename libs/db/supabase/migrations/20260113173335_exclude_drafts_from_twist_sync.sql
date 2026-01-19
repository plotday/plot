SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_pending_user_sync (p_user_id uuid)
    RETURNS TABLE (
        entity text,
        last_update_at timestamp with time zone)
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
    SELECT
        entity,
        last_update_at
    FROM
        user_sync
    WHERE
        user_id = p_user_id
        AND last_update_at > last_sync_at;
$function$;

CREATE OR REPLACE FUNCTION public.mark_user_sync_complete (p_user_id uuid)
    RETURNS void
    LANGUAGE sql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
    UPDATE
        user_sync
    SET
        last_sync_at = now()
    WHERE
        user_id = p_user_id
        AND last_update_at > last_sync_at;
$function$;

CREATE OR REPLACE FUNCTION public.sync_twist_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_updated_by integer;
    v_twists_to_notify uuid[] := '{}';
    v_priority_twist_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- Only consider non-draft activities (draft activities are invisible to twists)
    -- When an activity transitions from draft=true to draft=false, it will be included
    -- and appear as a new item to twists
    SELECT
        MAX(updated_at) INTO v_max_updated_at
    FROM
        new_table
    WHERE
        draft = FALSE;
    -- Exit early if all changes were to draft activities
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the updated_by value (if any) to exclude that twist from notifications
    SELECT DISTINCT
        updated_by INTO v_updated_by
    FROM
        new_table
    WHERE
        updated_by IS NOT NULL
        AND draft = FALSE
    LIMIT 1;
    -- Get all twists with access to affected priorities
    -- Exclude the twist that made the update by comparing truncated UUID with updated_by
    -- Only consider non-draft activities
    FOR v_priority_twist_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN priority_child_twist pct ON pct.priority_child_id = n.priority_id
    WHERE
        n.draft = FALSE
        AND pct.archived_at IS NULL
        AND (v_updated_by IS NULL
            OR v_updated_by = 0
            OR (
                CASE WHEN ('x' ||
                RIGHT (REPLACE(pct.id::text, '-', ''),
                    16))::bit(64)::bigint < 0 THEN
                    (('x' ||
                        RIGHT (REPLACE(pct.id::text, '-', ''),
                            16))::bit(64)::bigint::numeric + 18446744073709551616::numeric) % 2147483647
                ELSE
                    ('x' ||
                    RIGHT (REPLACE(pct.id::text, '-', ''),
                        16))::bit(64)::bigint::numeric % 2147483647
                END) != v_updated_by)
            LOOP
                -- Get previous state
                SELECT
                    last_update_at,
                    last_sync_at INTO v_prev_update_at,
                    v_prev_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'activity';
                -- Upsert the sync record
                INSERT INTO priority_twist_sync (priority_twist_id, entity, last_update_at)
                    VALUES (v_priority_twist_id, 'activity', v_max_updated_at)
                ON CONFLICT (priority_twist_id, entity)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                -- Get the current sync_at after update
                SELECT
                    last_sync_at INTO v_current_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'activity';
                -- Check if we need to notify (same logic as user sync)
                IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                    v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                END IF;
            END LOOP;
    -- Batch notify all twists that need it
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        PERFORM
            call_twist_sync_api (v_twists_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_twist_for_activity_tag ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_updated_by integer;
    v_twists_to_notify uuid[] := '{}';
    v_priority_twist_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- Only consider tags on non-draft activities
    SELECT
        MAX(n.updated_at) INTO v_max_updated_at
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
    WHERE
        a.draft = FALSE;
    -- Exit early if all changes were to tags on draft activities
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the updated_by value (if any) to exclude that twist from notifications
    SELECT DISTINCT
        n.updated_by INTO v_updated_by
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
    WHERE
        n.updated_by IS NOT NULL
        AND a.draft = FALSE
    LIMIT 1;
    -- Get all twists with access to the parent activity's priority
    -- Exclude the twist that made the update by comparing truncated UUID with updated_by
    -- Only consider tags on non-draft activities
    FOR v_priority_twist_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
        JOIN priority_child_twist pct ON pct.priority_child_id = a.priority_id
    WHERE
        a.draft = FALSE
        AND pct.archived_at IS NULL
        AND (v_updated_by IS NULL
            OR v_updated_by = 0
            OR (
                CASE WHEN ('x' ||
                RIGHT (REPLACE(pct.id::text, '-', ''),
                    16))::bit(64)::bigint < 0 THEN
                    (('x' ||
                        RIGHT (REPLACE(pct.id::text, '-', ''),
                            16))::bit(64)::bigint::numeric + 18446744073709551616::numeric) % 2147483647
                ELSE
                    ('x' ||
                    RIGHT (REPLACE(pct.id::text, '-', ''),
                        16))::bit(64)::bigint::numeric % 2147483647
                END) != v_updated_by)
            LOOP
                SELECT
                    last_update_at,
                    last_sync_at INTO v_prev_update_at,
                    v_prev_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'activity';
                INSERT INTO priority_twist_sync (priority_twist_id, entity, last_update_at)
                    VALUES (v_priority_twist_id, 'activity', v_max_updated_at)
                ON CONFLICT (priority_twist_id, entity)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                SELECT
                    last_sync_at INTO v_current_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'activity';
                IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                    v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                END IF;
            END LOOP;
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        PERFORM
            call_twist_sync_api (v_twists_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_twist_for_note ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_updated_by integer;
    v_twists_to_notify uuid[] := '{}';
    v_priority_twist_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- Only consider non-draft notes on non-draft activities
    -- When a note transitions from draft=true to draft=false, it will be included
    -- and appear as a new item to twists
    SELECT
        MAX(n.updated_at) INTO v_max_updated_at
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
    WHERE
        n.draft = FALSE
        AND a.draft = FALSE;
    -- Exit early if all changes were to draft notes or notes on draft activities
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the updated_by value (if any) to exclude that twist from notifications
    SELECT DISTINCT
        n.updated_by INTO v_updated_by
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
    WHERE
        n.updated_by IS NOT NULL
        AND n.draft = FALSE
        AND a.draft = FALSE
    LIMIT 1;
    -- Get all twists with access to the parent activity's priority
    -- Exclude the twist that made the update by comparing truncated UUID with updated_by
    -- Only consider non-draft notes on non-draft activities
    FOR v_priority_twist_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN activity a ON a.id = n.activity_id
        JOIN priority_child_twist pct ON pct.priority_child_id = a.priority_id
    WHERE
        n.draft = FALSE
        AND a.draft = FALSE
        AND pct.archived_at IS NULL
        AND (v_updated_by IS NULL
            OR v_updated_by = 0
            OR (
                CASE WHEN ('x' ||
                RIGHT (REPLACE(pct.id::text, '-', ''),
                    16))::bit(64)::bigint < 0 THEN
                    (('x' ||
                        RIGHT (REPLACE(pct.id::text, '-', ''),
                            16))::bit(64)::bigint::numeric + 18446744073709551616::numeric) % 2147483647
                ELSE
                    ('x' ||
                    RIGHT (REPLACE(pct.id::text, '-', ''),
                        16))::bit(64)::bigint::numeric % 2147483647
                END) != v_updated_by)
            LOOP
                SELECT
                    last_update_at,
                    last_sync_at INTO v_prev_update_at,
                    v_prev_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'note';
                INSERT INTO priority_twist_sync (priority_twist_id, entity, last_update_at)
                    VALUES (v_priority_twist_id, 'note', v_max_updated_at)
                ON CONFLICT (priority_twist_id, entity)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                SELECT
                    last_sync_at INTO v_current_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'note';
                IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                    v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                END IF;
            END LOOP;
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        PERFORM
            call_twist_sync_api (v_twists_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_twist_for_note_tag ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_updated_by integer;
    v_twists_to_notify uuid[] := '{}';
    v_priority_twist_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- Only consider tags on non-draft notes on non-draft activities
    SELECT
        MAX(n.updated_at) INTO v_max_updated_at
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN activity a ON a.id = nt.activity_id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE;
    -- Exit early if all changes were to tags on draft notes or draft activities
    IF v_max_updated_at IS NULL THEN
        RETURN NULL;
    END IF;
    -- Get the updated_by value (if any) to exclude that twist from notifications
    SELECT DISTINCT
        n.updated_by INTO v_updated_by
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN activity a ON a.id = nt.activity_id
    WHERE
        n.updated_by IS NOT NULL
        AND nt.draft = FALSE
        AND a.draft = FALSE
    LIMIT 1;
    -- Get all twists with access to the parent note's activity's priority
    -- Exclude the twist that made the update by comparing truncated UUID with updated_by
    -- Only consider tags on non-draft notes on non-draft activities
    FOR v_priority_twist_id IN SELECT DISTINCT
        pct.id
    FROM
        new_table n
        JOIN note nt ON nt.id = n.note_id
        JOIN activity a ON a.id = nt.activity_id
        JOIN priority_child_twist pct ON pct.priority_child_id = a.priority_id
    WHERE
        nt.draft = FALSE
        AND a.draft = FALSE
        AND pct.archived_at IS NULL
        AND (v_updated_by IS NULL
            OR v_updated_by = 0
            OR (
                CASE WHEN ('x' ||
                RIGHT (REPLACE(pct.id::text, '-', ''),
                    16))::bit(64)::bigint < 0 THEN
                    (('x' ||
                        RIGHT (REPLACE(pct.id::text, '-', ''),
                            16))::bit(64)::bigint::numeric + 18446744073709551616::numeric) % 2147483647
                ELSE
                    ('x' ||
                    RIGHT (REPLACE(pct.id::text, '-', ''),
                        16))::bit(64)::bigint::numeric % 2147483647
                END) != v_updated_by)
            LOOP
                SELECT
                    last_update_at,
                    last_sync_at INTO v_prev_update_at,
                    v_prev_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'note';
                INSERT INTO priority_twist_sync (priority_twist_id, entity, last_update_at)
                    VALUES (v_priority_twist_id, 'note', v_max_updated_at)
                ON CONFLICT (priority_twist_id, entity)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                SELECT
                    last_sync_at INTO v_current_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'note';
                IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at) THEN
                    v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                END IF;
            END LOOP;
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        PERFORM
            call_twist_sync_api (v_twists_to_notify);
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
