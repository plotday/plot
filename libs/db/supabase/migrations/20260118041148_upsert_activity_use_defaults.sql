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
-- Upsert activity with smart handling
-- On INSERT: Infers required fields from defaults if provided
-- On UPDATE: Only updates fields whose keys are present in p_activity
--   - Key absent: keep existing value
--   - Key present (even with null): use provided value (allows clearing to NULL)
-- Derivation: Automatically derives source_priority_root, created_by_twist_id, and default assignee
--
-- Parameters:
--   p_activity: activity data as JSONB (explicitly provided values only)
--   p_defaults: default values as JSONB (all fields with defaults - used on INSERT if not in p_activity)
--
-- Assignee Derivation:
--   - If 'assignee_id' key exists in p_activity (even if null): use that value
--   - If 'assignee_id' key is absent AND type is 'action': derive from priority_twist owner
--
-- Returns: The full activity row (not just ID) so caller can process occurrences
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
    ELSIF p_defaults ? 'recurrence_exdates' AND p_defaults -> 'recurrence_exdates' IS NOT NULL THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_defaults -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    END IF;
    -- Perform the upsert and return the full row
    -- On INSERT: Use COALESCE to fall back to p_defaults for fields not in p_activity
    INSERT INTO activity (id, author_id, created_by, created_by_twist_id, assignee_id, priority_id, source_created_at, type, title, preview, at, "on", duration, done_at, recurrence_rule, recurrence_exdates, meta, source, updated_by, sync_depth, embedding, pick_priority, private, draft)
        VALUES (COALESCE((p_activity ->> 'id')::uuid, (p_defaults ->> 'id')::uuid, gen_random_uuid_v7 ()),
            v_author_id,
            v_created_by,
            v_created_by_twist_id,
            v_assignee_id,
            v_priority_id,
            COALESCE((p_activity ->> 'source_created_at')::timestamptz, (p_defaults ->> 'source_created_at')::timestamptz, now()),
            v_type,
            COALESCE(p_activity ->> 'title', p_defaults ->> 'title'),
            COALESCE(p_activity ->> 'preview', p_defaults ->> 'preview'),
            COALESCE((p_activity ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange),
            COALESCE((p_activity ->> 'on')::daterange, (p_defaults ->> 'on')::daterange),
            COALESCE((p_activity ->> 'duration')::interval, (p_defaults ->> 'duration')::interval),
            COALESCE((p_activity ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz),
            COALESCE(p_activity ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule'),
            v_recurrence_exdates,
            COALESCE(p_activity -> 'meta', p_defaults -> 'meta'),
            v_source,
            COALESCE((p_activity ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0),
            COALESCE((p_activity ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint),
            COALESCE((p_activity ->> 'embedding')::halfvec, (p_defaults ->> 'embedding')::halfvec),
            COALESCE(p_activity -> 'pick_priority', p_defaults -> 'pick_priority'),
            COALESCE((p_activity ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE),
            COALESCE((p_activity ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, FALSE))
    ON CONFLICT (source, source_priority_root)
        DO UPDATE SET
            -- Update fields only if key is present in p_activity
            -- Key absent: keep existing value
            -- Key present (even with null): use provided value (allows clearing)
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
            recurrence_exdates = CASE WHEN p_activity ? 'recurrence_exdates' THEN
                v_recurrence_exdates
            ELSE
                activity.recurrence_exdates
            END,
            meta = CASE WHEN p_activity ? 'meta' THEN
                p_activity -> 'meta'
            ELSE
                activity.meta
            END,
            updated_by = CASE WHEN p_activity ? 'updated_by' THEN
                (p_activity ->> 'updated_by')::integer
            ELSE
                activity.updated_by
            END,
            sync_depth = CASE WHEN p_activity ? 'sync_depth' THEN
                (p_activity ->> 'sync_depth')::smallint
            ELSE
                activity.sync_depth
            END,
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
            * INTO v_result;
    RETURN v_result;
END;
$function$;

-- Restrict access: only service_role can call this function
-- This function can create/update any activity, bypassing RLS
REVOKE EXECUTE ON FUNCTION public.upsert_activity (jsonb, jsonb) FROM PUBLIC;

