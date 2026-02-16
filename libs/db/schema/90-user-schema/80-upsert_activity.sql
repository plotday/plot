-- Upsert activity with smart handling
-- On INSERT: Infers required fields from defaults if provided
-- On UPDATE: Only updates fields whose keys are present in p_activity
--   - Key absent: keep existing value (unless activity is archived)
--   - Key present (even with null): use provided value (allows clearing to NULL)
--   - Archived activities: treated as INSERT, applying p_defaults for missing keys
-- Archived Detection: Activity is considered archived if:
--   - activity.archived_at IS NOT NULL, OR
--   - Priority is not accessible (no user.priority_expanded entry with NULL archived_at)
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
CREATE OR REPLACE FUNCTION "user".upsert_activity (user_id uuid, p_activity jsonb, p_defaults jsonb DEFAULT '{}' ::jsonb)
    RETURNS activity
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_result activity;
    v_id uuid;
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
    v_recurrence_exdates_add timestamptz[];
    v_recurrence_exdates_remove timestamptz[];
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_activity ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_source := p_activity ->> 'source';
    v_type := COALESCE((p_activity ->> 'type')::activity_type, (p_defaults ->> 'type')::activity_type, 'note'::activity_type);
    v_priority_id := COALESCE((p_activity ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_activity ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- When the user creates directly (not via twist), force author to their contact ID.
    -- This prevents impersonation: clients cannot spoof author_id.
    -- When a twist creates (created_by != user_id), trust the provided author_id.
    IF v_created_by = user_id THEN
        v_author_id := COALESCE("user".user_contact_id(user_id), user_id);
    ELSE
        v_author_id := COALESCE((p_activity ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid, v_created_by);
    END IF;
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
    -- Resolve id from source if not provided (for twist-created activities)
    IF v_id IS NULL
        AND v_source IS NOT NULL
        AND v_source_priority_root IS NOT NULL THEN
        SELECT
            a.id INTO v_id
        FROM
            activity a
        WHERE
            a.source = v_source
            AND a.source_priority_root = v_source_priority_root;
    END IF;
    -- Generate id if still not resolved
    IF v_id IS NULL THEN
        v_id := uuidv7 ();
    END IF;
    -- Resolve priority_id from existing activity if missing
    IF v_priority_id IS NULL THEN
        SELECT
            priority_id INTO v_priority_id
        FROM
            activity
        WHERE
            id = v_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    -- Validate access to the priority
    IF NOT EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority pp ON pu.priority_id = pp.id
            JOIN priority p ON p.path <@ pp.path
        WHERE
            pu.user_id = upsert_activity.user_id
            AND pu.archived_at IS NULL
            AND p.id = v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Validate created_by when it differs from user_id
    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT
                1
            FROM
                priority_twist pt
            WHERE
                pt.id = v_created_by
                AND pt.owner_id = upsert_activity.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
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
    IF p_activity ? 'recurrence_exdates' AND jsonb_typeof(p_activity -> 'recurrence_exdates') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_activity -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    ELSIF p_defaults ? 'recurrence_exdates'
            AND jsonb_typeof(p_defaults -> 'recurrence_exdates') = 'array' THEN
            SELECT
                ARRAY (
                    SELECT
                        (jsonb_array_elements_text(p_defaults -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    END IF;
    -- Handle add/remove exdates
    IF p_activity ? 'recurrence_exdates_add' AND jsonb_typeof(p_activity -> 'recurrence_exdates_add') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_activity -> 'recurrence_exdates_add'))::timestamptz) INTO v_recurrence_exdates_add;
    END IF;
    IF p_activity ? 'recurrence_exdates_remove' AND jsonb_typeof(p_activity -> 'recurrence_exdates_remove') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_activity -> 'recurrence_exdates_remove'))::timestamptz) INTO v_recurrence_exdates_remove;
    END IF;
    -- Check if existing activity is archived (either directly or via priority)
    -- Only relevant for UPDATE path; INSERT path will have NULL and be coalesced to false
    SELECT
        (activity.archived_at IS NOT NULL
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    "user".priority_expanded upe
                WHERE
                    upe.priority_id = activity.priority_id
                    AND upe.user_id = upsert_activity.user_id
                    AND upe.archived_at IS NULL)) INTO v_is_archived
    FROM
        activity
    WHERE
        id = v_id;
    -- If no existing activity, v_is_archived will be NULL (INSERT path)
    v_is_archived := COALESCE(v_is_archived, FALSE);
    -- Perform the upsert and return the full row
    -- On INSERT: Use COALESCE to fall back to p_defaults for fields not in p_activity
    INSERT INTO activity (id, author_id, created_by, created_by_twist_id, assignee_id, priority_id, source_created_at, type, title, preview, at, "on", duration, done_at, recurrence_rule, recurrence_exdates, meta, source, updated_by, sync_depth, embedding, pick_priority, private, draft, "order")
        VALUES (v_id, v_author_id, v_created_by, v_created_by_twist_id, v_assignee_id, v_priority_id, COALESCE((p_activity ->> 'source_created_at')::timestamptz, (p_defaults ->> 'source_created_at')::timestamptz, now()), v_type, COALESCE(p_activity ->> 'title', p_defaults ->> 'title'), COALESCE(p_activity ->> 'preview', p_defaults ->> 'preview'), COALESCE((p_activity ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange), COALESCE((p_activity ->> 'on')::daterange, (p_defaults ->> 'on')::daterange), COALESCE((p_activity ->> 'duration')::interval, (p_defaults ->> 'duration')::interval), COALESCE((p_activity ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz), COALESCE(p_activity ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule'), v_recurrence_exdates, COALESCE(p_activity -> 'meta', p_defaults -> 'meta'), v_source, COALESCE((p_activity ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0), COALESCE((p_activity ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint), COALESCE((p_activity ->> 'embedding')::halfvec, (p_defaults ->> 'embedding')::halfvec), COALESCE(p_activity -> 'pick_priority', p_defaults -> 'pick_priority'), COALESCE((p_activity ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE), COALESCE((p_activity ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, FALSE), COALESCE((p_activity ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, public.order_first()))
    ON CONFLICT (id)
        DO UPDATE SET
            -- Update fields only if key is present in p_activity
            -- Key absent: keep existing value (unless archived, then use p_defaults)
            -- Key present (even with null): use provided value (allows clearing)
            -- If archived: treat as INSERT and apply p_defaults
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_activity ->> 'title', p_defaults ->> 'title', activity.title)
            ELSE
                CASE WHEN p_activity ? 'title' THEN
                    p_activity ->> 'title'
                ELSE
                    activity.title
                END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_activity ->> 'preview', p_defaults ->> 'preview', activity.preview)
            ELSE
                CASE WHEN p_activity ? 'preview' THEN
                    p_activity ->> 'preview'
                ELSE
                    activity.preview
                END
            END,
            at = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange, activity.at)
            ELSE
                CASE WHEN p_activity ? 'at' THEN
                    (p_activity ->> 'at')::tstzrange
                ELSE
                    activity.at
                END
            END,
            "on" = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'on')::daterange, (p_defaults ->> 'on')::daterange, activity."on")
            ELSE
                CASE WHEN p_activity ? 'on' THEN
                    (p_activity ->> 'on')::daterange
                ELSE
                    activity."on"
                END
            END,
            duration = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'duration')::interval, (p_defaults ->> 'duration')::interval, activity.duration)
            ELSE
                CASE WHEN p_activity ? 'duration' THEN
                    (p_activity ->> 'duration')::interval
                ELSE
                    activity.duration
                END
            END,
            done_at = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'done_at')::timestamptz, (p_defaults ->> 'done_at')::timestamptz, activity.done_at)
            ELSE
                CASE WHEN p_activity ? 'done_at' THEN
                    (p_activity ->> 'done_at')::timestamptz
                ELSE
                    activity.done_at
                END
            END,
            recurrence_rule = CASE WHEN v_is_archived THEN
                COALESCE(p_activity ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule', activity.recurrence_rule)
            ELSE
                CASE WHEN p_activity ? 'recurrence_rule' THEN
                    p_activity ->> 'recurrence_rule'
                ELSE
                    activity.recurrence_rule
                END
            END,
            recurrence_exdates = CASE WHEN v_is_archived THEN
                -- v_recurrence_exdates already has p_activity fallback to p_defaults
                COALESCE(v_recurrence_exdates, activity.recurrence_exdates)
            WHEN p_activity ? 'recurrence_exdates' THEN
                -- Full replace
                v_recurrence_exdates
            WHEN v_recurrence_exdates_add IS NOT NULL OR v_recurrence_exdates_remove IS NOT NULL THEN
                -- Incremental add/remove
                (SELECT ARRAY(
                    SELECT DISTINCT unnest
                    FROM unnest(
                        COALESCE(activity.recurrence_exdates, ARRAY[]::timestamptz[]) ||
                        COALESCE(v_recurrence_exdates_add, ARRAY[]::timestamptz[])
                    )
                    WHERE unnest IS NOT NULL
                      AND (v_recurrence_exdates_remove IS NULL
                           OR unnest != ALL(v_recurrence_exdates_remove))
                    ORDER BY 1
                ))
            ELSE
                activity.recurrence_exdates
            END,
            meta = CASE WHEN v_is_archived THEN
                COALESCE(p_activity -> 'meta', p_defaults -> 'meta', activity.meta)
            ELSE
                CASE WHEN p_activity ? 'meta' THEN
                    p_activity -> 'meta'
                ELSE
                    activity.meta
                END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, activity.updated_by)
            ELSE
                CASE WHEN p_activity ? 'updated_by' THEN
                    (p_activity ->> 'updated_by')::integer
                ELSE
                    activity.updated_by
                END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, activity.sync_depth)
            ELSE
                CASE WHEN p_activity ? 'sync_depth' THEN
                    (p_activity ->> 'sync_depth')::smallint
                ELSE
                    activity.sync_depth
                END
            END,
            type = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'type')::activity_type, (p_defaults ->> 'type')::activity_type, activity.type)
            ELSE
                CASE WHEN p_activity ? 'type' THEN
                    (p_activity ->> 'type')::activity_type
                ELSE
                    activity.type
                END
            END,
            assignee_id = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'assignee_id')::uuid, (p_defaults ->> 'assignee_id')::uuid, v_assignee_id, activity.assignee_id)
            ELSE
                CASE WHEN p_activity ? 'assignee_id' THEN
                    (p_activity ->> 'assignee_id')::uuid
                ELSE
                    COALESCE(v_assignee_id, activity.assignee_id)
                END
            END,
            priority_id = CASE WHEN v_is_archived THEN
                v_priority_id
            ELSE
                CASE WHEN p_activity ? 'priority_id' THEN
                    (p_activity ->> 'priority_id')::uuid
                ELSE
                    activity.priority_id
                END
            END,
            private = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, activity.private)
            ELSE
                CASE WHEN p_activity ? 'private' THEN
                    (p_activity ->> 'private')::boolean
                ELSE
                    activity.private
                END
            END,
            archived_at = CASE WHEN v_is_archived THEN
                CASE WHEN p_activity ? 'archived_at' THEN
                    (p_activity ->> 'archived_at')::timestamptz
                WHEN p_defaults ? 'archived_at' THEN
                    (p_defaults ->> 'archived_at')::timestamptz
                ELSE
                    activity.archived_at
                END
            ELSE
                CASE WHEN p_activity ? 'archived_at' THEN
                    (p_activity ->> 'archived_at')::timestamptz
                ELSE
                    activity.archived_at
                END
            END,
            source = COALESCE(v_source, activity.source),
            source_priority_root = COALESCE(v_source_priority_root, activity.source_priority_root),
            created_by = v_created_by,
            created_by_twist_id = v_created_by_twist_id,
            "order" = CASE WHEN v_is_archived THEN
                COALESCE((p_activity ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, activity."order")
            ELSE
                CASE WHEN p_activity ? 'order' THEN
                    (p_activity ->> 'order')::double precision
                ELSE
                    activity."order"
                END
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$function$;
