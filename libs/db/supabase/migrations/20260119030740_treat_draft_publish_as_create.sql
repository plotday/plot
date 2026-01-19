DROP TRIGGER IF EXISTS "twist_sync_activity_update" ON "public"."activity";

DROP TRIGGER IF EXISTS "twist_sync_note_update" ON "public"."note";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.enforce_draft_rules ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Prevent unpublishing: draft cannot go from false to true
    IF OLD.draft = FALSE AND NEW.draft = TRUE THEN
        RAISE EXCEPTION 'Cannot change draft from false to true';
    END IF;
    -- Update created_at when publishing (draft: true -> false)
    IF OLD.draft = TRUE AND NEW.draft = FALSE THEN
        NEW.created_at = now();
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_twist_for_activity ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_updated_by integer;
    v_twists_to_notify uuid[] := '{}';
    v_priority_twist_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- Determine timestamps for create and update operations
    IF TG_OP = 'INSERT' THEN
        -- For inserts, all non-draft rows are creates
        SELECT
            MAX(created_at) INTO v_create_timestamp
        FROM
            new_table
        WHERE
            draft = FALSE;
    ELSE
        -- For UPDATE, check for "published" rows (draft true→false) vs regular updates
        -- "Published" rows: draft changed from TRUE to FALSE - treat as create
        SELECT
            MAX(n.updated_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE;
        -- Regular updated rows: was already published (not draft) and still not draft
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE;
    END IF;
    -- Exit early if all changes were to draft activities (nothing to sync)
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
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
    -- Process CREATE operations (new inserts or published drafts)
    IF v_create_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN priority_child_twist pct ON pct.priority_child_id = n.priority_id
            LEFT JOIN old_table o ON o.id = n.id
        WHERE
            n.draft = FALSE
            AND pct.archived_at IS NULL
            -- Only notify the twist that created this activity
            AND n.created_by = pct.id
            -- For INSERT: all non-draft; for UPDATE: only published (draft true→false)
            AND (TG_OP = 'INSERT'
                OR (o.draft = TRUE
                    AND n.draft = FALSE))
            AND (v_updated_by IS NULL
                OR v_updated_by = 0
                OR updated_by_uuid (pct.id) != v_updated_by)
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
                        AND operation = 'create';
                    INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                        VALUES (v_priority_twist_id, 'activity', 'create', v_create_timestamp)
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
                        AND operation = 'create';
                    IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_create_timestamp > v_current_sync_at + interval '60 seconds') THEN
                        v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                    END IF;
                END LOOP;
    END IF;
    -- Process UPDATE operations (regular updates to already-published activities)
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN priority_child_twist pct ON pct.priority_child_id = n.priority_id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND pct.archived_at IS NULL
            -- Only notify the twist that created this activity
            AND n.created_by = pct.id
            AND (v_updated_by IS NULL
                OR v_updated_by = 0
                OR updated_by_uuid (pct.id) != v_updated_by)
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
                        VALUES (v_priority_twist_id, 'activity', 'update', v_update_timestamp)
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
                    IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_update_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_update_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_update_timestamp > v_current_sync_at + interval '60 seconds') THEN
                        v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                    END IF;
                END LOOP;
    END IF;
    -- Batch notify all twists that need it
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
    v_create_timestamp timestamptz;
    v_update_timestamp timestamptz;
    v_updated_by integer;
    v_twists_to_notify uuid[] := '{}';
    v_priority_twist_id uuid;
    v_prev_update_at timestamptz;
    v_prev_sync_at timestamptz;
    v_current_sync_at timestamptz;
BEGIN
    -- Determine timestamps for create and update operations
    IF TG_OP = 'INSERT' THEN
        -- For inserts, all non-draft notes on non-draft activities are creates
        SELECT
            MAX(n.created_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN activity a ON a.id = n.activity_id
        WHERE
            n.draft = FALSE
            AND a.draft = FALSE;
    ELSE
        -- For UPDATE, check for "published" rows (draft true→false) vs regular updates
        -- "Published" rows: draft changed from TRUE to FALSE - treat as create
        SELECT
            MAX(n.updated_at) INTO v_create_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN activity a ON a.id = n.activity_id
        WHERE
            o.draft = TRUE
            AND n.draft = FALSE
            AND a.draft = FALSE;
        -- Regular updated rows: was already published (not draft) and still not draft
        SELECT
            MAX(n.updated_at) INTO v_update_timestamp
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN activity a ON a.id = n.activity_id
        WHERE
            o.draft = FALSE
            AND n.draft = FALSE
            AND a.draft = FALSE;
    END IF;
    -- Exit early if all changes were to draft notes or notes on draft activities
    IF v_create_timestamp IS NULL AND v_update_timestamp IS NULL THEN
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
    -- Process CREATE operations (new inserts or published drafts)
    -- For creates: notify twist if it created the activity OR is mentioned in any note on the activity
    IF v_create_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN activity a ON a.id = n.activity_id
            JOIN priority_child_twist pct ON pct.priority_child_id = a.priority_id
            LEFT JOIN old_table o ON o.id = n.id
        WHERE
            n.draft = FALSE
            AND a.draft = FALSE
            AND pct.archived_at IS NULL
            -- For INSERT: all non-draft; for UPDATE: only published (draft true→false)
            AND (TG_OP = 'INSERT'
                OR (o.draft = TRUE
                    AND n.draft = FALSE))
            -- Notify if created activity OR mentioned anywhere in thread
            AND (a.created_by = pct.id
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
            AND (v_updated_by IS NULL
                OR v_updated_by = 0
                OR updated_by_uuid (pct.id) != v_updated_by)
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
                        AND operation = 'create';
                    INSERT INTO priority_twist_sync (priority_twist_id, entity, operation, last_update_at)
                        VALUES (v_priority_twist_id, 'note', 'create', v_create_timestamp)
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
                        AND operation = 'create';
                    IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_create_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_create_timestamp > v_current_sync_at + interval '60 seconds') THEN
                        v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                    END IF;
                END LOOP;
    END IF;
    -- Process UPDATE operations (regular updates to already-published notes)
    -- For updates: only notify twist that created the note
    IF v_update_timestamp IS NOT NULL THEN
        FOR v_priority_twist_id IN SELECT DISTINCT
            pct.id
        FROM
            new_table n
            JOIN old_table o ON o.id = n.id
            JOIN activity a ON a.id = n.activity_id
            JOIN priority_child_twist pct ON pct.priority_child_id = a.priority_id
        WHERE
            n.draft = FALSE
            AND o.draft = FALSE
            AND a.draft = FALSE
            AND pct.archived_at IS NULL
            -- Only notify note creator
            AND n.created_by = pct.id
            AND (v_updated_by IS NULL
                OR v_updated_by = 0
                OR updated_by_uuid (pct.id) != v_updated_by)
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
                        VALUES (v_priority_twist_id, 'note', 'update', v_update_timestamp)
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
                    IF (v_prev_update_at IS NULL) OR (v_prev_update_at <= v_prev_sync_at AND v_update_timestamp > v_current_sync_at) OR (v_prev_update_at > v_prev_sync_at AND v_prev_sync_at IS DISTINCT FROM v_current_sync_at AND v_update_timestamp > v_current_sync_at) OR (v_current_sync_at IS NOT NULL AND v_update_timestamp > v_current_sync_at + interval '60 seconds') THEN
                        v_twists_to_notify := array_append(v_twists_to_notify, v_priority_twist_id);
                    END IF;
                END LOOP;
    END IF;
    IF array_length(v_twists_to_notify, 1) > 0 THEN
        PERFORM
            call_twist_sync_api (v_twists_to_notify);
    END IF;
    RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.updated_by_uuid (id uuid)
    RETURNS numeric
    LANGUAGE sql
    IMMUTABLE
    AS $function$
    SELECT
        CASE WHEN ('x' ||
        RIGHT (REPLACE(id::text, '-', ''),
            16))::bit(64)::bigint < 0 THEN
            (('x' ||
                RIGHT (REPLACE(id::text, '-', ''),
                    16))::bit(64)::bigint::numeric + 18446744073709551616::numeric) % 2147483647
        ELSE
            ('x' ||
            RIGHT (REPLACE(id::text, '-', ''),
                16))::bit(64)::bigint::numeric % 2147483647
        END
$function$;

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
    ax.source,
    ax.meta,
    ax.mentions,
    author.name AS author_name,
    author.type AS author_type,
    p.title AS priority_title,
    at.tags
FROM ((((priority_child_twist pct
                JOIN activity_x ax ON (ax.priority_id = pct.priority_child_id))
            LEFT JOIN actor author ON (author.id = ax.author_id))
        LEFT JOIN priority p ON (p.id = ax.priority_id))
    LEFT JOIN activity_tags at ON (((at.activity_id = ax.id)
                AND (at.occurrence IS NULL))))
WHERE ((ax.draft = FALSE)
    AND (ax.updated_at > ax.created_at)
    AND (updated_by_uuid (pct.id) <> (ax.updated_by)::numeric)
    AND (pct.archived_at IS NULL)
    AND (ax.updated_at > pct.created_at))
ORDER BY
    ax.updated_at;

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
    ax.priority_id,
    ax.title AS activity_title,
    ax.created_by AS activity_created_by,
    ax.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
FROM ((((priority_child_twist pct
                JOIN activity_x ax ON (ax.priority_id = pct.priority_child_id))
            JOIN note n ON (ax.id = n.activity_id))
        LEFT JOIN actor author ON (author.id = n.author_id))
    LEFT JOIN note_tags nt ON (nt.note_id = n.id))
WHERE ((n.draft = FALSE)
    AND (n.updated_at > n.created_at)
    AND (updated_by_uuid (pct.id) <> (n.updated_by)::numeric)
    AND (ax.archived_at IS NULL)
    AND (pct.archived_at IS NULL)
    AND (n.updated_at > pct.created_at))
ORDER BY
    n.updated_at;

CREATE TRIGGER twist_sync_activity_update
    AFTER UPDATE ON public.activity REFERENCING OLD TABLE AS old_table NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION sync_twist_for_activity ();

CREATE TRIGGER twist_sync_note_update
    AFTER UPDATE ON public.note REFERENCING OLD TABLE AS old_table NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION sync_twist_for_note ();

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
ALTER VIEW "public"."priority_twist_activity_create" SET ( security_invoker = TRUE);
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
