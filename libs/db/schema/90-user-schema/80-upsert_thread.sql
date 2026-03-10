-- Upsert thread with smart handling
-- On INSERT: Infers required fields from defaults if provided
-- On UPDATE: Only updates fields whose keys are present in p_thread
--   - Key absent: keep existing value (unless thread is archived)
--   - Key present (even with null): use provided value (allows clearing to NULL)
--   - Archived threads: treated as INSERT, applying p_defaults for missing keys
-- Archived Detection: Thread is considered archived if:
--   - thread.archived_at IS NOT NULL, OR
--   - Priority is not accessible (no user.priority_expanded entry with NULL archived_at)
--
-- Parameters:
--   p_thread: thread data as JSONB (explicitly provided values only)
--   p_defaults: default values as JSONB (all fields with defaults - used on INSERT if not in p_thread)
--
-- Returns: The full thread row (not just ID) so caller can process occurrences
CREATE OR REPLACE FUNCTION "user".upsert_thread (user_id uuid, p_thread jsonb, p_defaults jsonb DEFAULT '{}' ::jsonb)
    RETURNS thread
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_result thread;
    v_id uuid;
    -- Variables for derived values
    v_priority_id uuid;
    v_created_by uuid;
    -- Archived status check
    v_is_archived boolean;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    -- Generate id if not provided
    IF v_id IS NULL THEN
        v_id := uuidv7 ();
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
    -- Validate access to the priority
    IF NOT EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority pp ON pu.priority_id = pp.id
            JOIN priority p ON p.path <@ pp.path
        WHERE
            pu.user_id = upsert_thread.user_id
            AND pu.archived_at IS NULL
            AND p.id = v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Enforce viewer restriction: viewers cannot create or modify threads
    IF "user".get_effective_role(user_id, v_priority_id) = 'viewer' THEN
        RAISE EXCEPTION 'Viewer members cannot create or modify threads';
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
    INSERT INTO thread (id, created_by, priority_id, title, preview, updated_by, sync_depth, private, draft)
        VALUES (v_id, v_created_by, v_priority_id, COALESCE(p_thread ->> 'title', p_defaults ->> 'title'), COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview'), COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0), COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint), COALESCE((p_thread ->> 'private')::boolean, (p_defaults ->> 'private')::boolean, FALSE), COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, FALSE))
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
$function$;
