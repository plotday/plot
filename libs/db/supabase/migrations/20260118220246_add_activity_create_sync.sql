SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."priority_twist_activity_create" AS
SELECT
    ax.created_by AS priority_twist_id,
    ax.id,
    ax.created_at,
    ax.updated_at,
    ax.source_created_at,
    ax.author_id,
    ax.created_by,
    ax.assignee_id,
    ax.updated_by,
    ax.sync_depth,
    ax.archived_at,
    ax.priority_id,
    ax.type,
    ax."order",
    ax.draft,
    ax.private,
    ax.title,
    ax.preview,
    ax.at,
    ax."on",
    ax.duration,
    ax.done_at,
    ax.recurrence_rule,
    ax.recurrence_exdates,
    ax.source,
    ax.meta,
    ax.mentions,
    author.name AS author_name,
    author.type AS author_type,
    p.title AS priority_title,
    at.tags
FROM ((((activity_x ax
                JOIN priority_child_twist pct ON (((pct.priority_child_id = ax.priority_id)
                            AND (pct.id = ax.created_by))))
            LEFT JOIN actor author ON (author.id = ax.author_id))
        LEFT JOIN priority p ON (p.id = ax.priority_id))
    LEFT JOIN activity_tags at ON (((at.activity_id = ax.id)
                AND (at.occurrence IS NULL))))
WHERE (ax.draft = FALSE);

CREATE OR REPLACE FUNCTION public.sync_twist_for_activity ()
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
            MAX(created_at) INTO v_max_timestamp
        FROM
            new_table
        WHERE
            draft = FALSE;
    ELSE
        v_operation := 'update';
        -- For updates, use updated_at as the timestamp
        SELECT
            MAX(updated_at) INTO v_max_timestamp
        FROM
            new_table
        WHERE
            draft = FALSE;
    END IF;
    -- Exit early if all changes were to draft activities
    IF v_max_timestamp IS NULL THEN
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
                    AND operation = v_operation;
                -- Upsert the sync record
                INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                    VALUES (v_priority_twist_id, 'activity', v_operation, v_max_timestamp)
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
                    AND operation = v_operation;
                -- Check if we need to notify (same logic as user sync)
                IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_max_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_max_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_max_timestamp > v_current_sync_at + interval '60 seconds') THEN
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

CREATE TRIGGER twist_sync_activity_insert
    AFTER INSERT ON public.activity REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION sync_twist_for_activity ();

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
ALTER VIEW "public"."priority_twist_activity_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_create" SET (security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_tag_change" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
