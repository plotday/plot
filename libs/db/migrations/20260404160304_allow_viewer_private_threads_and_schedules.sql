-- Modify "setup_plot_app_priority" function
CREATE OR REPLACE FUNCTION "public"."setup_plot_app_priority" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority_id uuid;
    v_priority_path ltree;
    v_contact_id uuid;
    v_user_root_path ltree;
    v_override_path ltree;
BEGIN
    -- Get or create @plot.app priority
    SELECT
        id,
        path INTO v_priority_id,
        v_priority_path
    FROM
        priority
    WHERE
        key = '@plot.app'
    LIMIT 1;
    IF v_priority_id IS NULL THEN
        v_priority_path := generate_path (NULL);
        INSERT INTO priority (created_by, title, path, color, key, updated_by)
            VALUES (p_user_id, 'Using Plot', v_priority_path, 7, '@plot.app', 0)
        RETURNING
            id INTO v_priority_id;
        -- Clean up any auto-created personal entry
        DELETE FROM priority_user
        WHERE user_id = p_user_id
            AND priority_id = v_priority_id
            AND personal = TRUE;
    END IF;
    -- Get user's contact_id
    SELECT
        id INTO v_contact_id
    FROM
        contact
    WHERE
        user_id = p_user_id
        AND "primary" = TRUE
    LIMIT 1;
    -- Add priority_contact (idempotent)
    IF v_contact_id IS NOT NULL THEN
        INSERT INTO priority_contact (priority_id, contact_id)
            VALUES (v_priority_id, v_contact_id)
        ON CONFLICT (priority_id, contact_id)
            DO NOTHING;
    END IF;
    -- Add priority_user with viewer role (idempotent - don't overwrite existing role)
    INSERT INTO priority_user (user_id, priority_id, personal, role)
        VALUES (p_user_id, v_priority_id, FALSE, 'viewer')
    ON CONFLICT (user_id, priority_id)
        DO NOTHING;
    -- Position under user's root via priority_settings
    SELECT
        p.path INTO v_user_root_path
    FROM
        priority_user pu
        JOIN priority p ON pu.priority_id = p.id
    WHERE
        pu.user_id = p_user_id
        AND pu.personal = TRUE
    LIMIT 1;
    IF v_user_root_path IS NOT NULL THEN
        v_override_path := generate_path (v_user_root_path);
        INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, v_priority_id, 'path', to_jsonb (ltree2text (v_override_path)))
        ON CONFLICT (user_id, priority_id, key)
            DO UPDATE SET
                value = EXCLUDED.value;
        INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, v_priority_id, 'title', to_jsonb ('Using Plot'::text))
        ON CONFLICT (user_id, priority_id, key)
            DO UPDATE SET
                value = EXCLUDED.value;
    END IF;
    RETURN jsonb_build_object('success', TRUE, 'priority_id', v_priority_id);
END;
$$;
-- Modify "upsert_schedule" function
CREATE OR REPLACE FUNCTION "user"."upsert_schedule" ("user_id" uuid, "p_schedule" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."schedule" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
DECLARE
    v_id uuid;
    v_thread_id uuid;
    v_link_id uuid;
    v_priority_id uuid;
    v_role text;
    v_schedule_user_id uuid;
    v_recurrence_exdates timestamptz[];
    v_recurrence_exdates_add timestamptz[];
    v_recurrence_exdates_remove timestamptz[];
    v_result schedule;
BEGIN
    -- Extract fields
    v_id := COALESCE((p_schedule ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_thread_id := COALESCE((p_schedule ->> 'thread_id')::uuid, (p_defaults ->> 'thread_id')::uuid);
    v_link_id := COALESCE((p_schedule ->> 'link_id')::uuid, (p_defaults ->> 'link_id')::uuid);
    v_schedule_user_id := COALESCE((p_schedule ->> 'user_id')::uuid, (p_defaults ->> 'user_id')::uuid);

    -- Resolve thread_id/link_id from existing schedule if updating
    IF v_thread_id IS NULL AND v_link_id IS NULL AND v_id IS NOT NULL THEN
        SELECT
            s.thread_id, s.link_id INTO v_thread_id, v_link_id
        FROM
            schedule s
        WHERE
            s.id = v_id;
    END IF;

    -- Must have either thread_id or link_id
    IF v_thread_id IS NULL AND v_link_id IS NULL THEN
        RAISE EXCEPTION 'thread_id or link_id must be provided';
    END IF;

    -- Look up priority and check access + role in a single query
    IF v_thread_id IS NOT NULL THEN
        SELECT
            a.priority_id,
            CASE WHEN bool_or(pu.role = 'member') THEN 'member' ELSE COALESCE(MAX(pu.role), NULL) END
        INTO v_priority_id, v_role
        FROM
            thread a
            JOIN priority p ON p.id = a.priority_id
            LEFT JOIN priority pp ON p.path <@ pp.path
            LEFT JOIN priority_user pu ON pu.priority_id = pp.id
                AND pu.user_id = upsert_schedule.user_id
                AND pu.archived_at IS NULL
        WHERE
            a.id = v_thread_id
        GROUP BY a.priority_id;
        IF v_priority_id IS NULL THEN
            RAISE EXCEPTION 'Thread not found';
        END IF;
    ELSIF v_link_id IS NOT NULL THEN
        SELECT
            t.priority_id,
            CASE WHEN bool_or(pu.role = 'member') THEN 'member' ELSE COALESCE(MAX(pu.role), NULL) END
        INTO v_priority_id, v_role
        FROM
            link l
            JOIN thread t ON t.id = l.thread_id
            JOIN priority p ON p.id = t.priority_id
            LEFT JOIN priority pp ON p.path <@ pp.path
            LEFT JOIN priority_user pu ON pu.priority_id = pp.id
                AND pu.user_id = upsert_schedule.user_id
                AND pu.archived_at IS NULL
        WHERE
            l.id = v_link_id
        GROUP BY t.priority_id;
        IF v_priority_id IS NULL THEN
            RAISE EXCEPTION 'Link not found';
        END IF;
    END IF;

    IF v_role IS NULL THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    IF v_role = 'viewer' THEN
        -- Viewers can only create/modify per-user schedules for themselves
        IF v_schedule_user_id IS NULL OR v_schedule_user_id != upsert_schedule.user_id THEN
            RAISE EXCEPTION 'Viewer members can only create per-user schedules for themselves';
        END IF;
    END IF;

    -- Per-user schedules can only be created/modified by the owning user
    IF v_schedule_user_id IS NOT NULL AND v_schedule_user_id != upsert_schedule.user_id THEN
        RAISE EXCEPTION 'Cannot create/modify per-user schedule for another user';
    END IF;

    -- Resolve to existing schedule ID based on unique constraints.
    -- This prevents unique constraint violations when client and server
    -- have different UUIDs for the same logical schedule.
    DECLARE
        v_occurrence text;
        v_existing_id uuid;
    BEGIN
        v_occurrence := COALESCE(p_schedule ->> 'occurrence', p_defaults ->> 'occurrence');

        IF v_occurrence IS NOT NULL THEN
            -- Occurrence override: resolve by (link_id/thread_id, occurrence)
            IF v_link_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.link_id = v_link_id
                  AND s.occurrence = v_occurrence;
            ELSIF v_thread_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.thread_id = v_thread_id
                  AND s.occurrence = v_occurrence;
            END IF;
        ELSIF v_schedule_user_id IS NOT NULL THEN
            -- Per-user base schedule: resolve by (link_id/thread_id, user_id)
            IF v_link_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.link_id = v_link_id
                  AND s.user_id = v_schedule_user_id
                  AND s.occurrence IS NULL;
            ELSIF v_thread_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.thread_id = v_thread_id
                  AND s.user_id = v_schedule_user_id
                  AND s.occurrence IS NULL;
            END IF;
        ELSE
            -- Shared base schedule: resolve by (link_id/thread_id, user_id IS NULL)
            IF v_link_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.link_id = v_link_id
                  AND s.user_id IS NULL
                  AND s.occurrence IS NULL;
            ELSIF v_thread_id IS NOT NULL THEN
                SELECT s.id INTO v_existing_id
                FROM schedule s
                WHERE s.thread_id = v_thread_id
                  AND s.user_id IS NULL
                  AND s.occurrence IS NULL;
            END IF;
        END IF;

        IF v_existing_id IS NOT NULL THEN
            v_id := v_existing_id;
        END IF;
    END;

    -- Generate id if not provided
    IF v_id IS NULL THEN
        v_id := uuidv7 ();
    END IF;

    -- Handle recurrence_exdates array conversion from JSONB
    IF p_schedule ? 'recurrence_exdates' AND jsonb_typeof(p_schedule -> 'recurrence_exdates') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_schedule -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    ELSIF p_defaults ? 'recurrence_exdates'
            AND jsonb_typeof(p_defaults -> 'recurrence_exdates') = 'array' THEN
            SELECT
                ARRAY (
                    SELECT
                        (jsonb_array_elements_text(p_defaults -> 'recurrence_exdates'))::timestamptz) INTO v_recurrence_exdates;
    END IF;

    -- Handle add/remove exdates
    IF p_schedule ? 'recurrence_exdates_add' AND jsonb_typeof(p_schedule -> 'recurrence_exdates_add') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_schedule -> 'recurrence_exdates_add'))::timestamptz) INTO v_recurrence_exdates_add;
    END IF;
    IF p_schedule ? 'recurrence_exdates_remove' AND jsonb_typeof(p_schedule -> 'recurrence_exdates_remove') = 'array' THEN
        SELECT
            ARRAY (
                SELECT
                    (jsonb_array_elements_text(p_schedule -> 'recurrence_exdates_remove'))::timestamptz) INTO v_recurrence_exdates_remove;
    END IF;

    -- Perform the upsert
    INSERT INTO schedule (id, thread_id, link_id, user_id, "order", at, "on", recurrence_rule, duration, recurrence_exdates, occurrence, reason, archived_at, outstanding_tasks)
        VALUES (
            v_id,
            v_thread_id,
            v_link_id,
            v_schedule_user_id,
            CASE WHEN v_schedule_user_id IS NOT NULL THEN
                COALESCE((p_schedule ->> 'order')::double precision, (p_defaults ->> 'order')::double precision, public.order_first())
            ELSE
                NULL
            END,
            COALESCE((p_schedule ->> 'at')::tstzrange, (p_defaults ->> 'at')::tstzrange),
            COALESCE((p_schedule ->> 'on')::daterange, (p_defaults ->> 'on')::daterange),
            COALESCE(p_schedule ->> 'recurrence_rule', p_defaults ->> 'recurrence_rule'),
            COALESCE((p_schedule ->> 'duration')::interval, (p_defaults ->> 'duration')::interval),
            v_recurrence_exdates,
            COALESCE(p_schedule ->> 'occurrence', p_defaults ->> 'occurrence'),
            COALESCE(p_schedule ->> 'reason', p_defaults ->> 'reason'),
            COALESCE((p_schedule ->> 'archived_at')::timestamptz, (p_defaults ->> 'archived_at')::timestamptz),
            COALESCE((p_schedule ->> 'outstanding_tasks')::boolean, (p_defaults ->> 'outstanding_tasks')::boolean, FALSE)
        )
    ON CONFLICT (id)
        DO UPDATE SET
            at = CASE WHEN p_schedule ? 'at' THEN
                (p_schedule ->> 'at')::tstzrange
            WHEN p_schedule ? 'on' THEN
                NULL -- Clear at when on is being set (XOR constraint)
            ELSE
                schedule.at
            END,
            "on" = CASE WHEN p_schedule ? 'on' THEN
                (p_schedule ->> 'on')::daterange
            WHEN p_schedule ? 'at' THEN
                NULL -- Clear on when at is being set (XOR constraint)
            ELSE
                schedule."on"
            END,
            recurrence_rule = CASE WHEN p_schedule ? 'recurrence_rule' THEN
                p_schedule ->> 'recurrence_rule'
            ELSE
                schedule.recurrence_rule
            END,
            duration = CASE WHEN p_schedule ? 'duration' THEN
                (p_schedule ->> 'duration')::interval
            ELSE
                schedule.duration
            END,
            recurrence_exdates = CASE WHEN p_schedule ? 'recurrence_exdates' THEN
                v_recurrence_exdates
            WHEN v_recurrence_exdates_add IS NOT NULL OR v_recurrence_exdates_remove IS NOT NULL THEN
                (SELECT ARRAY(
                    SELECT DISTINCT unnest
                    FROM unnest(
                        COALESCE(schedule.recurrence_exdates, ARRAY[]::timestamptz[]) ||
                        COALESCE(v_recurrence_exdates_add, ARRAY[]::timestamptz[])
                    )
                    WHERE unnest IS NOT NULL
                      AND (v_recurrence_exdates_remove IS NULL
                           OR unnest != ALL(v_recurrence_exdates_remove))
                    ORDER BY 1
                ))
            ELSE
                schedule.recurrence_exdates
            END,
            "order" = CASE
                WHEN schedule.user_id IS NULL THEN NULL
                WHEN p_schedule ? 'order' THEN COALESCE((p_schedule ->> 'order')::double precision, schedule."order", public.order_first())
                ELSE COALESCE(schedule."order", public.order_first())
            END,
            reason = CASE WHEN p_schedule ? 'reason' THEN
                CASE
                    WHEN schedule.reason IS NULL THEN (p_schedule ->> 'reason')
                    WHEN schedule.reason = 'unread' AND (p_schedule ->> 'reason') IN ('task', 'add', 'schedule') THEN (p_schedule ->> 'reason')
                    WHEN schedule.reason = 'task' AND (p_schedule ->> 'reason') IN ('add', 'schedule') THEN (p_schedule ->> 'reason')
                    WHEN schedule.reason = 'add' AND (p_schedule ->> 'reason') = 'schedule' THEN 'schedule'
                    ELSE schedule.reason
                END
            ELSE schedule.reason
            END,
            archived_at = CASE WHEN p_schedule ? 'archived_at' THEN
                (p_schedule ->> 'archived_at')::timestamptz
            ELSE
                schedule.archived_at
            END,
            outstanding_tasks = CASE WHEN p_schedule ? 'outstanding_tasks' THEN
                (p_schedule ->> 'outstanding_tasks')::boolean
            ELSE
                schedule.outstanding_tasks
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
-- Modify "upsert_thread" function
CREATE OR REPLACE FUNCTION "user"."upsert_thread" ("user_id" uuid, "p_thread" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."thread" LANGUAGE plpgsql AS $$
DECLARE
    v_result thread;
    v_id uuid;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    v_role text;
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- Generate id if not provided
    -- If key is provided and no id was given, look up existing thread by key + priority
    IF v_id IS NULL THEN
        IF (p_thread ? 'key') AND v_priority_id IS NOT NULL THEN
            SELECT id INTO v_id
            FROM thread
            WHERE key = (p_thread ->> 'key')
              AND priority_id = v_priority_id;
        END IF;
        IF v_id IS NULL THEN
            v_id := uuidv7 ();
        END IF;
    END IF;
    -- Resolve priority_id from existing thread if missing
    IF v_priority_id IS NULL THEN
        SELECT
            priority_id INTO v_priority_id
        FROM
            thread
        WHERE
            id = v_id;
    END IF;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    -- Validate access and role in a single query
    SELECT
        CASE WHEN bool_or(pu.role = 'member') THEN 'member' ELSE COALESCE(MAX(pu.role), NULL) END
    INTO v_role
    FROM
        priority_user pu
        JOIN priority pp ON pu.priority_id = pp.id
        JOIN priority p ON p.path <@ pp.path
    WHERE
        pu.user_id = upsert_thread.user_id
        AND pu.archived_at IS NULL
        AND p.id = v_priority_id;
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    IF v_role = 'viewer' THEN
        -- Viewers can only create private threads; they cannot modify existing
        -- non-private threads or change a thread from private to non-private
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = v_id) THEN
            -- New thread: must be private
            IF COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE) IS NOT TRUE THEN
                RAISE EXCEPTION 'Viewer members can only create private threads';
            END IF;
        ELSE
            -- Existing thread: viewers can only modify their own private threads
            IF NOT EXISTS (
                SELECT 1 FROM thread
                WHERE id = v_id AND private = TRUE AND created_by = user_id
            ) THEN
                RAISE EXCEPTION 'Viewer members cannot modify threads they did not create';
            END IF;
        END IF;
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
                AND pt.owner_id = upsert_thread.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
    END IF;
    -- Check if existing thread is archived (either directly or via priority)
    -- Only relevant for UPDATE path; INSERT path will have NULL and be coalesced to false
    SELECT
        (thread.archived_at IS NOT NULL
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    "user".priority_expanded upe
                WHERE
                    upe.priority_id = thread.priority_id
                    AND upe.user_id = upsert_thread.user_id
                    AND upe.archived_at IS NULL)) INTO v_is_archived
    FROM
        thread
    WHERE
        id = v_id;
    -- If no existing thread, v_is_archived will be NULL (INSERT path)
    v_is_archived := COALESCE(v_is_archived, FALSE);
    -- Perform the upsert and return the full row
    -- On INSERT: Use COALESCE to fall back to p_defaults for fields not in p_thread
    INSERT INTO thread (id, created_by, priority_id, title, preview, updated_by, sync_depth, private, draft, key, icon)
        VALUES (v_id, v_created_by, v_priority_id, COALESCE(p_thread ->> 'title', p_defaults ->> 'title'), COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview'), COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0), COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint), COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE), COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, FALSE), COALESCE(p_thread ->> 'key', p_defaults ->> 'key'), COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon'))
    ON CONFLICT (id)
        DO UPDATE SET
            -- Update fields only if key is present in p_thread
            -- Key absent: keep existing value (unless archived, then use p_defaults)
            -- Key present (even with null): use provided value (allows clearing)
            -- If archived: treat as INSERT and apply p_defaults
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'title', p_defaults ->> 'title', thread.title)
            ELSE
                CASE WHEN p_thread ? 'title' THEN
                    p_thread ->> 'title'
                ELSE
                    thread.title
                END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', thread.preview)
            ELSE
                CASE WHEN p_thread ? 'preview' THEN
                    p_thread ->> 'preview'
                ELSE
                    thread.preview
                END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, thread.updated_by)
            ELSE
                CASE WHEN p_thread ? 'updated_by' THEN
                    (p_thread ->> 'updated_by')::integer
                ELSE
                    thread.updated_by
                END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, thread.sync_depth)
            ELSE
                CASE WHEN p_thread ? 'sync_depth' THEN
                    (p_thread ->> 'sync_depth')::smallint
                ELSE
                    thread.sync_depth
                END
            END,
            priority_id = CASE WHEN v_is_archived THEN
                v_priority_id
            ELSE
                CASE WHEN p_thread ? 'priority_id' THEN
                    (p_thread ->> 'priority_id')::uuid
                ELSE
                    thread.priority_id
                END
            END,
            private = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, thread.private)
            ELSE
                CASE WHEN p_thread ? 'private' THEN
                    (p_thread ->> 'private')::boolean
                ELSE
                    thread.private
                END
            END,
            draft = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, thread.draft)
            ELSE
                CASE WHEN p_thread ? 'draft' THEN
                    (p_thread ->> 'draft')::boolean
                ELSE
                    thread.draft
                END
            END,
            icon = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', thread.icon)
            ELSE
                CASE WHEN p_thread ? 'icon' THEN
                    p_thread ->> 'icon'
                ELSE
                    thread.icon
                END
            END,
            archived_at = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                WHEN p_defaults ? 'archived_at' THEN
                    (p_defaults ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            ELSE
                CASE WHEN p_thread ? 'archived_at' THEN
                    (p_thread ->> 'archived_at')::timestamptz
                ELSE
                    thread.archived_at
                END
            END,
            created_by = v_created_by
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
