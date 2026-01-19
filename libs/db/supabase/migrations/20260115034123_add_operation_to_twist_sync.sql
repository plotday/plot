CREATE TYPE "public"."sync_operation" AS enum (
    'create',
    'update'
);

-- Clear existing sync records since the schema is changing
-- New records will be created with the correct operation type
DELETE FROM "public"."priority_twist_sync";

ALTER TABLE "public"."priority_twist_sync"
    DROP CONSTRAINT "priority_twist_sync_pkey";

DROP INDEX IF EXISTS "public"."priority_twist_sync_pkey";

ALTER TABLE "public"."priority_twist_sync"
    ADD COLUMN "operation" sync_operation NOT NULL;

CREATE UNIQUE INDEX priority_twist_sync_pkey ON public.priority_twist_sync USING btree (priority_twist_id, entity, operation);

ALTER TABLE "public"."priority_twist_sync"
    ADD CONSTRAINT "priority_twist_sync_pkey" PRIMARY KEY USING INDEX "priority_twist_sync_pkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.get_stale_twist_syncs (p_stale_threshold timestamp with time zone, p_limit integer DEFAULT 50)
    RETURNS TABLE (
        priority_twist_id uuid)
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
    SELECT DISTINCT
        pts.priority_twist_id
    FROM
        priority_twist_sync pts
    WHERE
        pts.last_update_at > pts.last_sync_at -- Has pending updates
        AND pts.last_sync_at < p_stale_threshold -- Hasn't synced recently
    ORDER BY
        pts.priority_twist_id -- Deterministic ordering after DISTINCT
    LIMIT p_limit;
$function$;

CREATE OR REPLACE FUNCTION public.get_stale_user_syncs (p_stale_threshold timestamp with time zone, p_limit integer DEFAULT 50)
    RETURNS TABLE (
        user_id uuid)
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
    SELECT DISTINCT
        us.user_id
    FROM
        user_sync us
    WHERE
        us.last_update_at > us.last_sync_at -- Has pending updates
        AND us.last_sync_at < p_stale_threshold -- Hasn't synced recently
    ORDER BY
        us.user_id -- Deterministic ordering after DISTINCT
    LIMIT p_limit;
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
    -- Get twists that created the affected activities
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
        -- Only notify the twist that created this activity
        AND n.created_by = pct.id
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
                    AND entity = 'activity'
                    AND operation = 'update';
                -- Upsert the sync record
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'activity', 'update', v_max_updated_at)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                -- Get the current sync_at after update
                SELECT
                    last_sync_at INTO v_current_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'activity'
                    AND operation = 'update';
                -- Check if we need to notify (same logic as user sync)
                IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_max_updated_at > v_current_sync_at + interval '60 seconds') THEN
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
    -- Get twists that created the affected activities
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
        -- Only notify the twist that created this activity
        AND a.created_by = pct.id
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
                    AND entity = 'activity'
                    AND operation = 'update';
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'activity', 'update', v_max_updated_at)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                SELECT
                    last_sync_at INTO v_current_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'activity'
                    AND operation = 'update';
                IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_max_updated_at > v_current_sync_at + interval '60 seconds') THEN
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
    v_max_timestamp timestamptz;
    v_operation sync_operation;
    v_updated_by integer;
    v_twists_to_notify uuid[] := '{}';
    v_priority_twist_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- Determine operation type and appropriate timestamp
    IF TG_OP = 'INSERT' THEN
        v_operation := 'create';
        -- For creates, use created_at as the timestamp
        SELECT
            MAX(n.created_at) INTO v_max_timestamp
        FROM
            new_table n
            JOIN activity a ON a.id = n.activity_id
        WHERE
            n.draft = FALSE
            AND a.draft = FALSE;
    ELSE
        v_operation := 'update';
        -- For updates, use updated_at as the timestamp
        SELECT
            MAX(n.updated_at) INTO v_max_timestamp
        FROM
            new_table n
            JOIN activity a ON a.id = n.activity_id
        WHERE
            n.draft = FALSE
            AND a.draft = FALSE;
    END IF;
    -- Exit early if all changes were to draft notes or notes on draft activities
    IF v_max_timestamp IS NULL THEN
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
    -- Get twists that should be notified based on operation type:
    -- INSERT: notify twist if it created the activity OR is mentioned in any note on the activity
    -- UPDATE: only notify twist that created the note
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
        -- Filter based on operation type
        AND (
            CASE WHEN TG_OP = 'INSERT' THEN
                -- For INSERT: notify if created activity OR mentioned anywhere in thread
                (a.created_by = pct.id
                    OR pct.id = ANY (n.mentions)
                    OR EXISTS (
                        SELECT
                            1
                        FROM
                            note
                        WHERE
                            note.activity_id = a.id
                            AND note.id != n.id
                            AND pct.id = ANY (note.mentions)
                            AND note.archived_at IS NULL))
            ELSE
                -- For UPDATE: only notify note creator
                n.created_by = pct.id
            END)
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
                    AND entity = 'note'
                    AND operation = v_operation;
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'note', v_operation, v_max_timestamp)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                SELECT
                    last_sync_at INTO v_current_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'note'
                    AND operation = v_operation;
                IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_max_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_max_timestamp > v_current_sync_at + interval '60 seconds') THEN
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
    -- Get twists that created the affected notes
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
        -- Only notify the twist that created this note
        AND nt.created_by = pct.id
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
                    AND entity = 'note'
                    AND operation = 'update';
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'note', 'update', v_max_updated_at)
                ON CONFLICT (priority_twist_id, entity, operation)
                    DO UPDATE SET
                        last_update_at = GREATEST (priority_twist_sync.last_update_at, EXCLUDED.last_update_at);
                SELECT
                    last_sync_at INTO v_current_sync_at
                FROM
                    priority_twist_sync
                WHERE
                    priority_twist_id = v_priority_twist_id
                    AND entity = 'note'
                    AND operation = 'update';
                IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_max_updated_at > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_max_updated_at > v_current_sync_at + interval '60 seconds') THEN
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
