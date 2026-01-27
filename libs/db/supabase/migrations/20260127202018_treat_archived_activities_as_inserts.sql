SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.upsert_activity (p_activity jsonb, p_defaults jsonb DEFAULT '{}' ::jsonb)
    RETURNS activity
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
DECLARE
    v_result activity;
    v_source text;
    v_source_priority_root ltree;
    v_type activity_type;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    v_created_by_twist_id bigint;
    v_assignee_id uuid;
    v_author_id uuid;
    -- Array handling
    v_recurrence_exdates timestamptz[];
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_source := p_activity ->> 'source';
    v_type := COALESCE((p_activity ->> 'type')::activity_type, (p_defaults ->> 'type')::activity_type, 'note'::activity_type);
    v_priority_id := COALESCE((p_activity ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_activity ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid);
    v_author_id := COALESCE((p_activity ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid);
    -- DERIVE source_priority_root from priority_id when source exists but root not provided
    IF p_activity ? 'source_priority_root' AND (p_activity ->> 'source_priority_root') IS NOT NULL THEN
        v_source_priority_root := (p_activity ->> 'source_priority_root')::ltree;
    ELSIF v_source IS NOT NULL
            AND v_priority_id IS NOT NULL THEN
            SELECT
                subpath (p.path, 0, 1) INTO v_source_priority_root
            FROM
                priority p
            WHERE
                p.id = v_priority_id;
    END IF;
    -- DERIVE created_by_twist_id from created_by (priority_twist_id)
    IF p_activity ? 'created_by_twist_id' AND (p_activity ->> 'created_by_twist_id') IS NOT NULL THEN
        v_created_by_twist_id := (p_activity ->> 'created_by_twist_id')::bigint;
    ELSIF v_created_by IS NOT NULL THEN
        SELECT
            pt.twist_id INTO v_created_by_twist_id
        FROM
            priority_twist pt
        WHERE
            pt.id = v_created_by;
    END IF;
    -- DERIVE default assignee for actions when assignee_id key is absent from both p_activity and p_defaults
    -- If key exists in p_activity (even with null value), use that value
    -- If key exists in p_defaults (even with null value), use that value
    -- If key is absent from both AND type is action, derive from priority_twist owner
    IF p_activity ? 'assignee_id' THEN
        v_assignee_id := (p_activity ->> 'assignee_id')::uuid;
    ELSIF p_defaults ? 'assignee_id' THEN
        v_assignee_id := (p_defaults ->> 'assignee_id')::uuid;
    ELSIF v_type = 'action'
            AND v_created_by IS NOT NULL THEN
            v_assignee_id := get_priority_twist_owner_contact (v_created_by);
    ELSE
        v_assignee_id := NULL;
    END IF;
    -- Handle recurrence_exdates array conversion from JSONB (p_activity takes precedence over p_defaults)
    IF p_activity ? 'recurrence_exdates' AND p_activity -> 'recurrence_exdates' IS NOT NULL THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_activity -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    ELSIF p_defaults ? 'recurrence_exdates'
            AND p_defaults -> 'recurrence_exdates' IS NOT NULL THEN
            SELECT
                ARRAY (
                    SELECT
                        (jsonb_array_elements_text(p_defaults -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    END IF;
    -- Check if existing activity is archived (either directly or via priority)
    -- Only relevant for UPDATE path; INSERT path will have NULL and be coalesced to false
    SELECT
        (activity.archived_at IS NOT NULL
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    user_priority_expanded
                WHERE
                    priority_id = activity.priority_id
                    AND archived_at IS NULL)) INTO v_is_archived
    FROM
        activity
    WHERE
        source = v_source
        AND source_priority_root = v_source_priority_root;
    -- If no existing activity, v_is_archived will be NULL (INSERT path)
    v_is_archived := COALESCE(v_is_archived, FALSE);
    -- Perform the upsert and return the full row
    -- On INSERT: Use COALESCE to fall back to p_defaults for fields not in p_activity
    INSERT INTO activity (id, author_id, created_by, created_by_twist_id, assignee_id, priority_id, source_created_at, type, title, preview, at, "on", duration, done_at, recurrence_rule, recurrence_exdates, meta, source, updated_by, sync_depth, embedding, pick_priority, private, draft)
        VALUES (COALESCE((p_activity ->> 'id')::uuid, (p_defaults ->> 'id')::uuid, gen_random_uuid_v7 ()), v_author_id, v_created_by, v_created_by_twist_id, v_assignee_id, v_priority_id, COALESCE((p_activity ->> 'source_created_at')::timestamptz, (p_defaults ->> 'source_created_at')::timestamptz, now()), v_type, COALESCE(p_activity ->> 'title', p_defaults ->> 'title'), COALESCE(p_activity ->> 'preview', p_defaults ->> 'preview'), COALESCE((p_activity ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange), COALESCE((p_activity ->> 'on')::daterange, (p_defaults ->> 'on')::daterange), COALESCE((p_activity ->> 'duration')::interval, (p_defaults ->> 'duration')::interval), COALESCE((p_activity ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz), COALESCE(p_activity ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule'), v_recurrence_exdates, COALESCE(p_activity -> 'meta', p_defaults -> 'meta'), v_source, COALESCE((p_activity ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0), COALESCE((p_activity ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint), COALESCE((p_activity ->> 'embedding')::halfvec, (p_defaults ->> 'embedding')::halfvec), COALESCE(p_activity -> 'pick_priority', p_defaults -> 'pick_priority'), COALESCE((p_activity ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE), COALESCE((p_activity ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, FALSE))
    ON CONFLICT (source, source_priority_root)
        DO UPDATE SET
            -- Update fields only if key is present in p_activity
            -- Key absent: keep existing value (unless archived, then use p_defaults)
            -- Key present (even with null): use provided value (allows clearing)
            -- If archived: treat as INSERT and apply p_defaults
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_activity ->> 'title', p_defaults ->> 'title')
            ELSE
                CASE WHEN p_activity ? 'title' THEN
                    p_activity ->> 'title'
                ELSE
                    activity.title
                END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_activity ->> 'preview', p_defaults ->> 'preview')
            ELSE
                CASE WHEN p_activity ? 'preview' THEN
                    p_activity ->> 'preview'
                ELSE
                    activity.preview
                END
            END,
            at = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange)
            ELSE
                CASE WHEN p_activity ? 'at' THEN
                    (p_activity ->> 'at')::tstzrange
                ELSE
                    activity.at
                END
            END,
            "on" = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'on')::daterange, (p_defaults ->> 'on')::daterange)
            ELSE
                CASE WHEN p_activity ? 'on' THEN
                    (p_activity ->> 'on')::daterange
                ELSE
                    activity."on"
                END
            END,
            duration = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'duration')::interval, (p_defaults ->> 'duration')::interval)
            ELSE
                CASE WHEN p_activity ? 'duration' THEN
                    (p_activity ->> 'duration')::interval
                ELSE
                    activity.duration
                END
            END,
            done_at = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz)
            ELSE
                CASE WHEN p_activity ? 'done_at' THEN
                    (p_activity ->> 'done_at')::timestamptz
                ELSE
                    activity.done_at
                END
            END,
            recurrence_rule = CASE WHEN v_is_archived THEN
                COALESCE(p_activity ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule')
            ELSE
                CASE WHEN p_activity ? 'recurrence_rule' THEN
                    p_activity ->> 'recurrence_rule'
                ELSE
                    activity.recurrence_rule
                END
            END,
            recurrence_exdates = CASE WHEN v_is_archived THEN
                -- v_recurrence_exdates already has p_activity fallback to p_defaults
                v_recurrence_exdates
            ELSE
                CASE WHEN p_activity ? 'recurrence_exdates' THEN
                    v_recurrence_exdates
                ELSE
                    activity.recurrence_exdates
                END
            END,
            meta = CASE WHEN v_is_archived THEN
                COALESCE(p_activity -> 'meta', p_defaults -> 'meta')
            ELSE
                CASE WHEN p_activity ? 'meta' THEN
                    p_activity -> 'meta'
                ELSE
                    activity.meta
                END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer)
            ELSE
                CASE WHEN p_activity ? 'updated_by' THEN
                    (p_activity ->> 'updated_by')::integer
                ELSE
                    activity.updated_by
                END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint)
            ELSE
                CASE WHEN p_activity ? 'sync_depth' THEN
                    (p_activity ->> 'sync_depth')::smallint
                ELSE
                    activity.sync_depth
                END
            END,
            type = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'type')::activity_type, (p_defaults ->> 'type')::activity_type)
            ELSE
                CASE WHEN p_activity ? 'type' THEN
                    (p_activity ->> 'type')::activity_type
                ELSE
                    activity.type
                END
            END,
            assignee_id = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'assignee_id')::uuid, (p_defaults ->> 'assignee_id')::uuid)
            ELSE
                CASE WHEN p_activity ? 'assignee_id' THEN
                    (p_activity ->> 'assignee_id')::uuid
                ELSE
                    activity.assignee_id
                END
            END,
            private = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'private')::boolean, (p_defaults ->> 'private')::boolean)
            ELSE
                CASE WHEN p_activity ? 'private' THEN
                    (p_activity ->> 'private')::boolean
                ELSE
                    activity.private
                END
            END,
            archived_at = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'archived_at')::timestamptz, (p_defaults ->> 'archived_at')::timestamptz)
            ELSE
                CASE WHEN p_activity ? 'archived_at' THEN
                    (p_activity ->> 'archived_at')::timestamptz
                ELSE
                    activity.archived_at
                END
            END,
            created_by = v_created_by,
            created_by_twist_id = v_created_by_twist_id
        RETURNING
            * INTO v_result;
    RETURN v_result;
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
ALTER VIEW "public"."priority_twist_activity_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_tag_change" SET ( security_invoker = TRUE);
ALTER VIEW public.priority_member SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
