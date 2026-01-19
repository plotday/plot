SET check_function_bodies = OFF;

CREATE OR REPLACE VIEW "public"."priority_twist_activity_tag_change" AS
SELECT
    a.created_by AS priority_twist_id,
    at.activity_id,
    at.tag_id,
    at.actor_id,
    at.updated_at,
    CASE WHEN (at.archived_at IS NULL) THEN
        'added'::text
    ELSE
        'removed'::text
    END AS change_type
FROM ((activity_tag at
        JOIN activity a ON (a.id = at.activity_id))
    JOIN priority_child_twist pct ON (((pct.priority_child_id = a.priority_id)
                AND (pct.id = a.created_by))))
WHERE (a.draft = FALSE);

CREATE OR REPLACE VIEW "public"."priority_twist_activity_update" AS
SELECT
    ax.created_by AS priority_twist_id,
    ax.id,
    ax.created_at,
    GREATEST (ax.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
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
    ax.recurrence_dates,
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

CREATE OR REPLACE VIEW "public"."priority_twist_note_create" AS
SELECT
    pct.id AS priority_twist_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.key,
    n.mentions,
    a.priority_id,
    a.title AS activity_title,
    a.created_by AS activity_created_by,
    a.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags,
    fm.first_mentioned_at
FROM ((((((priority_child_twist pct
                        JOIN activity a ON (a.priority_id = pct.priority_child_id))
                    JOIN note n ON (n.activity_id = a.id))
                LEFT JOIN activity_x ax ON (ax.id = a.id))
            LEFT JOIN actor author ON (author.id = n.author_id))
        LEFT JOIN note_tags nt ON (nt.note_id = n.id))
    LEFT JOIN LATERAL (
        SELECT
            min(note.created_at) AS first_mentioned_at
        FROM
            note
        WHERE ((note.activity_id = a.id)
            AND (pct.id = ANY (note.mentions))
            AND (note.archived_at IS NULL))) fm ON (TRUE))
WHERE ((n.draft = FALSE)
    AND (a.draft = FALSE)
    AND ((a.created_by = pct.id)
        OR ((fm.first_mentioned_at IS NOT NULL)
            AND (n.created_at >= fm.first_mentioned_at))));

CREATE OR REPLACE VIEW "public"."priority_twist_note_update" AS
SELECT
    n.created_by AS priority_twist_id,
    n.id,
    n.created_at,
    GREATEST (n.updated_at, COALESCE(nt.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.key,
    n.mentions,
    a.priority_id,
    a.title AS activity_title,
    a.created_by AS activity_created_by,
    a.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM (((((note n
                    JOIN activity a ON (a.id = n.activity_id))
                JOIN priority_child_twist pct ON (((pct.priority_child_id = a.priority_id)
                            AND (pct.id = n.created_by))))
            LEFT JOIN activity_x ax ON (ax.id = a.id))
        LEFT JOIN actor author ON (author.id = n.author_id))
    LEFT JOIN note_tags nt ON (nt.note_id = n.id))
WHERE ((n.draft = FALSE)
    AND (a.draft = FALSE));

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
