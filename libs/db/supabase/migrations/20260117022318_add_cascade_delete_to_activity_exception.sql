ALTER TABLE "public"."activity_exception"
    DROP CONSTRAINT "activity_exception_activity_id_fkey";

ALTER TABLE "public"."activity_exception"
    ADD CONSTRAINT "activity_exception_activity_id_fkey" FOREIGN KEY (activity_id) REFERENCES activity (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."activity_exception" validate CONSTRAINT "activity_exception_activity_id_fkey";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.upsert_activity (p_activity jsonb, p_occurrences jsonb DEFAULT '[]' ::jsonb)
    RETURNS uuid
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    v_activity_id uuid;
    v_source text;
    v_source_priority_root ltree;
    v_type activity_type;
    v_is_insert boolean := FALSE;
    v_first_occ jsonb;
    v_first_occ_start text;
    v_first_occ_end text;
    v_first_occ_is_date boolean;
    v_at tstzrange;
    v_on daterange;
    v_title text;
    v_recurrence_rule text;
    v_occ jsonb;
    v_occurrence_str text;
    v_has_field_overrides boolean;
    v_exc_at tstzrange;
    v_exc_on daterange;
    v_existing_at tstzrange;
    v_existing_on daterange;
    v_existing_title text;
    v_existing_recurrence_rule text;
BEGIN
    -- Extract required fields
    v_source := p_activity ->> 'source';
    v_source_priority_root := (p_activity ->> 'source_priority_root')::ltree;
    v_type := COALESCE((p_activity ->> 'type')::activity_type, 'note'::activity_type);
    -- Get first occurrence for potential defaults
    IF jsonb_array_length(p_occurrences) > 0 THEN
        v_first_occ := p_occurrences -> 0;
        v_first_occ_start := v_first_occ ->> 'start';
        v_first_occ_end := v_first_occ ->> 'end';
        -- Dates are YYYY-MM-DD format (10 chars), timestamps are longer
        v_first_occ_is_date := v_first_occ_start IS NOT NULL
            AND length(v_first_occ_start) = 10;
    END IF;
    -- Check if this will be an insert and get existing values for UPDATE case
    IF v_source IS NOT NULL THEN
        SELECT
            id,
            at,
            "on",
            title,
            recurrence_rule INTO v_activity_id,
            v_existing_at,
            v_existing_on,
            v_existing_title,
            v_existing_recurrence_rule
        FROM
            activity
        WHERE
            source = v_source
            AND source_priority_root = v_source_priority_root;
        v_is_insert := v_activity_id IS NULL;
    ELSE
        v_is_insert := TRUE;
    END IF;
    -- Validate: Events with occurrences must have start in first occurrence for INSERT
    -- This enforces the semantic distinction between NewActivityOccurrence (requires start)
    -- and ActivityOccurrenceUpdate (start optional, only for updating existing activities)
    IF v_is_insert AND v_type = 'event' AND jsonb_array_length(p_occurrences) > 0 AND v_first_occ_start IS NULL AND NOT (p_activity ? 'at' AND p_activity ->> 'at' IS NOT NULL) AND NOT (p_activity ? 'on' AND p_activity ->> 'on' IS NOT NULL) THEN
        RAISE EXCEPTION 'Cannot create event from occurrence without start value. Use NewActivityOccurrence with required start field.';
    END IF;
    -- Prepare INSERT values
    -- For INSERT: Use provided values or infer from first occurrence
    -- For UPDATE: Use existing values to satisfy constraints (ON CONFLICT will use UPDATE SET)
    IF v_is_insert THEN
        -- Title: use provided or fall back to first occurrence
        v_title := COALESCE(p_activity ->> 'title', v_first_occ ->> 'title');
        -- Scheduling: use provided at/on, or build from first occurrence
        IF p_activity ? 'at' AND p_activity ->> 'at' IS NOT NULL THEN
            v_at := (p_activity ->> 'at')::tstzrange;
        ELSIF p_activity ? 'on'
                AND p_activity ->> 'on' IS NOT NULL THEN
                v_on := (p_activity ->> 'on')::daterange;
        ELSIF v_type = 'event'
                AND v_first_occ_start IS NOT NULL THEN
                -- Build schedule from first occurrence
                IF v_first_occ_is_date THEN
                    v_on := daterange(v_first_occ_start::date, COALESCE(v_first_occ_end::date, v_first_occ_start::date + 1), '[)');
                ELSE
                    v_at := tstzrange(v_first_occ_start::timestamptz, COALESCE(v_first_occ_end::timestamptz, v_first_occ_start::timestamptz + INTERVAL '1 hour'), '[)');
                END IF;
        END IF;
        -- Recurrence rule: use provided, or set to '' if has occurrences
        IF p_activity ? 'recurrence_rule' THEN
            v_recurrence_rule := p_activity ->> 'recurrence_rule';
        ELSIF jsonb_array_length(p_occurrences) > 0 THEN
            v_recurrence_rule := '';
        END IF;
    ELSE
        -- For UPDATE: Use existing values for INSERT to satisfy constraints
        -- (The ON CONFLICT UPDATE will use the correct values from UPDATE SET)
        v_at := COALESCE((p_activity ->> 'at')::tstzrange, v_existing_at);
        v_on := COALESCE((p_activity ->> 'on')::daterange, v_existing_on);
        v_title := COALESCE(p_activity ->> 'title', v_existing_title);
        v_recurrence_rule := COALESCE(p_activity ->> 'recurrence_rule', v_existing_recurrence_rule);
    END IF;
    -- Perform the upsert
    INSERT INTO activity (id, author_id, created_by, created_by_twist_id, assignee_id, priority_id, source_created_at, type, title, preview, at, "on", duration, done_at, recurrence_rule, recurrence_exdates, meta, source, updated_by, sync_depth, embedding, pick_priority, private, draft)
        VALUES (COALESCE((p_activity ->> 'id')::uuid, gen_random_uuid_v7 ()),
            (p_activity ->> 'author_id')::uuid, (p_activity ->> 'created_by')::uuid, (p_activity ->> 'created_by_twist_id')::bigint, (p_activity ->> 'assignee_id')::uuid, (p_activity ->> 'priority_id')::uuid, COALESCE((p_activity ->> 'source_created_at')::timestamptz, now()), v_type, v_title, p_activity ->> 'preview', v_at, v_on, (p_activity ->> 'duration')::interval, (p_activity ->> 'done_at')::timestamptz, v_recurrence_rule, CASE WHEN p_activity ? 'recurrence_exdates'
                AND jsonb_typeof(p_activity -> 'recurrence_exdates') = 'array' THEN
                ARRAY (
                    SELECT
                        (elem)::timestamptz
                    FROM
                        jsonb_array_elements_text(p_activity -> 'recurrence_exdates') AS elem)
            ELSE
                NULL
            END,
            p_activity -> 'meta',
            v_source,
            COALESCE((p_activity ->> 'updated_by')::integer, 0),
            (p_activity ->> 'sync_depth')::integer,
            CASE WHEN p_activity ? 'embedding' THEN
                (p_activity ->> 'embedding')::halfvec (384)
            ELSE
                NULL
            END,
            p_activity -> 'pick_priority',
            COALESCE((p_activity ->> 'private')::boolean, FALSE),
            COALESCE((p_activity ->> 'draft')::boolean, FALSE))
ON CONFLICT (source,
    source_priority_root)
    DO UPDATE SET
        -- Only update fields that are explicitly provided in p_activity
        title = CASE WHEN p_activity ? 'title' THEN
            p_activity ->> 'title'
        ELSE
            activity.title
        END,
        preview = CASE WHEN p_activity ? 'preview' THEN
            p_activity ->> 'preview'
        ELSE
            activity.preview
        END,
        at = CASE WHEN p_activity ? 'at' THEN
            (p_activity ->> 'at')::tstzrange
        ELSE
            activity.at
        END,
        "on" = CASE WHEN p_activity ? 'on' THEN
            (p_activity ->> 'on')::daterange
        ELSE
            activity."on"
        END,
        duration = CASE WHEN p_activity ? 'duration' THEN
            (p_activity ->> 'duration')::interval
        ELSE
            activity.duration
        END,
        done_at = CASE WHEN p_activity ? 'done_at' THEN
            (p_activity ->> 'done_at')::timestamptz
        ELSE
            activity.done_at
        END,
        recurrence_rule = CASE WHEN p_activity ? 'recurrence_rule' THEN
            p_activity ->> 'recurrence_rule'
        ELSE
            activity.recurrence_rule
        END,
        recurrence_exdates = CASE WHEN p_activity ? 'recurrence_exdates'
            AND jsonb_typeof(p_activity -> 'recurrence_exdates') = 'array' THEN
            ARRAY (
                SELECT
                    (elem)::timestamptz
                FROM
                    jsonb_array_elements_text(p_activity -> 'recurrence_exdates') AS elem)
        ELSE
            activity.recurrence_exdates
        END,
        meta = CASE WHEN p_activity ? 'meta' THEN
            p_activity -> 'meta'
        ELSE
            activity.meta
        END,
        updated_by = COALESCE((p_activity ->> 'updated_by')::integer, activity.updated_by),
        sync_depth = COALESCE((p_activity ->> 'sync_depth')::integer, activity.sync_depth),
        type = CASE WHEN p_activity ? 'type' THEN
            (p_activity ->> 'type')::activity_type
        ELSE
            activity.type
        END,
        assignee_id = CASE WHEN p_activity ? 'assignee_id' THEN
            (p_activity ->> 'assignee_id')::uuid
        ELSE
            activity.assignee_id
        END,
        private = CASE WHEN p_activity ? 'private' THEN
            (p_activity ->> 'private')::boolean
        ELSE
            activity.private
        END,
        archived_at = CASE WHEN p_activity ? 'archived_at' THEN
            (p_activity ->> 'archived_at')::timestamptz
        ELSE
            activity.archived_at
        END
    RETURNING
        id INTO v_activity_id;
    -- Process occurrences
    FOR v_occ IN
    SELECT
        *
    FROM
        jsonb_array_elements(p_occurrences)
        LOOP
            -- Format occurrence string
            v_occurrence_str := v_occ ->> 'occurrence';
            IF v_occurrence_str IS NULL THEN
                CONTINUE;
            END IF;
            -- Check if this occurrence has field overrides
            v_has_field_overrides := v_occ ? 'start'
                OR v_occ ? 'end'
                OR v_occ ? 'done'
                OR v_occ ? 'title'
                OR v_occ ? 'preview'
                OR v_occ ? 'meta'
                OR v_occ ? 'archived';
            IF v_has_field_overrides THEN
                -- Reset scheduling fields
                v_exc_at := NULL;
                v_exc_on := NULL;
                -- Build scheduling from start/end
                IF v_occ ? 'start' AND v_occ ->> 'start' IS NOT NULL THEN
                    -- Dates are YYYY-MM-DD format (10 chars), timestamps are longer
                    IF length(v_occ ->> 'start') = 10 THEN
                        v_exc_on := daterange((v_occ ->> 'start')::date, COALESCE((v_occ ->> 'end')::date, (v_occ ->> 'start')::date + 1), '[)');
                    ELSE
                        v_exc_at := tstzrange((v_occ ->> 'start')::timestamptz, COALESCE((v_occ ->> 'end')::timestamptz, (v_occ ->> 'start')::timestamptz + INTERVAL '1 hour'), '[)');
                    END IF;
                END IF;
                -- Upsert activity_exception
                INSERT INTO activity_exception (activity_id, occurrence, title, preview, at, "on", done_at, meta, archived_at, updated_by)
                    VALUES (v_activity_id, v_occurrence_str, CASE WHEN v_occ ? 'title' THEN
                            v_occ ->> 'title'
                        ELSE
                            NULL
                        END, CASE WHEN v_occ ? 'preview' THEN
                            v_occ ->> 'preview'
                        ELSE
                            NULL
                        END, v_exc_at, v_exc_on, CASE WHEN v_occ ? 'done'
                            AND v_occ ->> 'done' IS NOT NULL THEN
                            (v_occ ->> 'done')::timestamptz
                        ELSE
                            NULL
                        END, CASE WHEN v_occ ? 'meta' THEN
                            v_occ -> 'meta'
                        ELSE
                            NULL
                        END, CASE WHEN (v_occ ->> 'archived')::boolean THEN
                            now()
                        ELSE
                            NULL
                        END, COALESCE((p_activity ->> 'updated_by')::integer, 0))
                ON CONFLICT (activity_id, occurrence)
                    DO UPDATE SET
                        title = CASE WHEN v_occ ? 'title' THEN
                            v_occ ->> 'title'
                        ELSE
                            activity_exception.title
                        END,
                        preview = CASE WHEN v_occ ? 'preview' THEN
                            v_occ ->> 'preview'
                        ELSE
                            activity_exception.preview
                        END,
                        at = CASE WHEN v_occ ? 'start' THEN
                            v_exc_at
                        ELSE
                            activity_exception.at
                        END,
                        "on" = CASE WHEN v_occ ? 'start' THEN
                            v_exc_on
                        ELSE
                            activity_exception."on"
                        END,
                        done_at = CASE WHEN v_occ ? 'done' THEN
                            (v_occ ->> 'done')::timestamptz
                        ELSE
                            activity_exception.done_at
                        END,
                        meta = CASE WHEN v_occ ? 'meta' THEN
                            v_occ -> 'meta'
                        ELSE
                            activity_exception.meta
                        END,
                        archived_at = CASE WHEN v_occ ? 'archived' THEN
                            CASE WHEN (v_occ ->> 'archived')::boolean THEN
                                now()
                            ELSE
                                NULL
                            END
                        ELSE
                            activity_exception.archived_at
                        END,
                        updated_by = COALESCE((p_activity ->> 'updated_by')::integer, activity_exception.updated_by);
            END IF;
            -- Note: tags are not handled here - they need to be processed separately
            -- via update_activity_tags RPC which handles actor resolution
        END LOOP;
    RETURN v_activity_id;
END;
$function$;

CREATE OR REPLACE VIEW "public"."user_activity" AS
SELECT
    upe.user_id,
    a.id,
    a.created_at,
    GREATEST (a.updated_at, COALESCE(uau.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        tstzrange(a.done_at, a.done_at, '[]'::text)
    WHEN ((a.assignee_id IS NOT NULL)
        AND (ac.user_id <> upe.user_id)) THEN
        tstzrange(GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), '[)'::text)
    WHEN (a.at IS NOT NULL) THEN
        a.at
    WHEN (a."on" IS NOT NULL) THEN
        NULL::tstzrange
    ELSE
        tstzrange(GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), GREATEST (a.source_created_at, COALESCE(a.last_note_source_created_at, a.source_created_at)), '[)'::text)
    END AS range_at,
    CASE WHEN (a.done_at IS NOT NULL) THEN
        NULL::daterange
    WHEN ((a.assignee_id IS NOT NULL)
        AND (ac.user_id <> upe.user_id)) THEN
        NULL::daterange
    WHEN (a.at IS NOT NULL) THEN
        NULL::daterange
    WHEN (a."on" IS NOT NULL) THEN
        a."on"
    ELSE
        NULL::daterange
    END AS range_on,
    COALESCE(uau.unread, FALSE) AS unread
FROM (((activity_x a
            JOIN user_priority_expanded upe ON (a.priority_id = upe.priority_id))
        LEFT JOIN contact ac ON (ac.id = a.assignee_id))
    LEFT JOIN user_activity_unread uau ON (((uau.user_id = upe.user_id)
                AND (uau.activity_id = a.id))));

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
