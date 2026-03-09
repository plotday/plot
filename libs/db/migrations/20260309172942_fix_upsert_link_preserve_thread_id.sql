-- Modify "upsert_link" function
CREATE OR REPLACE FUNCTION "user"."upsert_link" ("user_id" uuid, "p_link" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."link" LANGUAGE plpgsql AS $$
DECLARE
    v_result link;
    v_id uuid;
    v_thread_id uuid;
    v_source text;
    v_source_priority_root ltree;
    v_created_by uuid;
    v_twist_id bigint;
    v_author_id uuid;
    v_assignee_id uuid;
    v_priority_id uuid;
BEGIN
    -- Extract required fields from JSONB, with fallback to p_defaults for INSERT
    v_id := COALESCE((p_link ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_thread_id := COALESCE((p_link ->> 'thread_id')::uuid, (p_defaults ->> 'thread_id')::uuid);
    v_source := p_link ->> 'source';
    v_created_by := COALESCE((p_link ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    v_author_id := COALESCE((p_link ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid, v_created_by);

    -- DERIVE source_priority_root from thread's priority when source exists
    IF p_link ? 'source_priority_root' AND (p_link ->> 'source_priority_root') IS NOT NULL THEN
        v_source_priority_root := (p_link ->> 'source_priority_root')::ltree;
    ELSIF v_source IS NOT NULL AND v_thread_id IS NOT NULL THEN
        SELECT
            subpath (p.path, 0, 1) INTO v_source_priority_root
        FROM
            thread t
            JOIN priority p ON p.id = t.priority_id
        WHERE
            t.id = v_thread_id;
    END IF;

    -- Resolve id from source if not provided (for twist-created links)
    IF v_id IS NULL
        AND v_source IS NOT NULL
        AND v_source_priority_root IS NOT NULL THEN
        SELECT
            l.id INTO v_id
        FROM
            link l
        WHERE
            l.source = v_source
            AND l.source_priority_root = v_source_priority_root;
    END IF;

    -- Generate id if still not resolved
    IF v_id IS NULL THEN
        v_id := uuidv7 ();
    END IF;

    -- Resolve thread_id from existing link if missing
    IF v_thread_id IS NULL THEN
        SELECT
            l.thread_id INTO v_thread_id
        FROM
            link l
        WHERE
            l.id = v_id;
    END IF;

    IF v_thread_id IS NULL THEN
        RAISE EXCEPTION 'thread_id must be provided';
    END IF;

    -- Get priority_id from thread for access check
    SELECT
        t.priority_id INTO v_priority_id
    FROM
        thread t
    WHERE
        t.id = v_thread_id;

    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
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
            pu.user_id = upsert_link.user_id
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
                AND pt.owner_id = upsert_link.user_id) THEN
            RAISE EXCEPTION 'created_by must be user or owned priority_twist';
        END IF;
    END IF;

    -- DERIVE twist_id from created_by (priority_twist_id)
    IF p_link ? 'twist_id' AND (p_link ->> 'twist_id') IS NOT NULL THEN
        v_twist_id := (p_link ->> 'twist_id')::bigint;
    ELSIF v_created_by IS NOT NULL THEN
        SELECT
            pt.twist_id INTO v_twist_id
        FROM
            priority_twist pt
        WHERE
            pt.id = v_created_by;
    END IF;

    -- Resolve assignee
    IF p_link ? 'assignee_id' THEN
        v_assignee_id := (p_link ->> 'assignee_id')::uuid;
    ELSIF p_defaults ? 'assignee_id' THEN
        v_assignee_id := (p_defaults ->> 'assignee_id')::uuid;
    ELSE
        v_assignee_id := NULL;
    END IF;

    -- Perform the upsert and return the full row
    INSERT INTO link (id, thread_id, source, source_created_at, author_id, twist_id,
        created_by, updated_by, sync_depth, title, preview, assignee_id, type, status,
        actions, meta, source_url, embedding, match, merged_from_thread_id)
        VALUES (v_id, v_thread_id, v_source,
            COALESCE((p_link ->> 'source_created_at')::timestamptz, (p_defaults ->> 'source_created_at')::timestamptz, now()),
            v_author_id, v_twist_id, v_created_by,
            COALESCE((p_link ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, 0),
            COALESCE((p_link ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint),
            COALESCE(p_link ->> 'title', p_defaults ->> 'title'),
            COALESCE(p_link ->> 'preview', p_defaults ->> 'preview'),
            v_assignee_id,
            COALESCE(p_link ->> 'type', p_defaults ->> 'type'),
            COALESCE(p_link ->> 'status', p_defaults ->> 'status'),
            COALESCE(p_link -> 'actions', p_defaults -> 'actions'),
            COALESCE(p_link -> 'meta', p_defaults -> 'meta'),
            COALESCE(p_link ->> 'source_url', p_defaults ->> 'source_url'),
            COALESCE((p_link ->> 'embedding')::halfvec, (p_defaults ->> 'embedding')::halfvec),
            COALESCE(p_link -> 'match', p_defaults -> 'match'),
            COALESCE((p_link ->> 'merged_from_thread_id')::uuid, (p_defaults ->> 'merged_from_thread_id')::uuid))
    ON CONFLICT (id)
        DO UPDATE SET
            title = CASE WHEN p_link ? 'title' THEN
                p_link ->> 'title'
            ELSE
                link.title
            END,
            preview = CASE WHEN p_link ? 'preview' THEN
                p_link ->> 'preview'
            ELSE
                link.preview
            END,
            assignee_id = CASE WHEN p_link ? 'assignee_id' THEN
                (p_link ->> 'assignee_id')::uuid
            ELSE
                COALESCE(v_assignee_id, link.assignee_id)
            END,
            type = CASE WHEN p_link ? 'type' THEN
                p_link ->> 'type'
            ELSE
                link.type
            END,
            status = CASE WHEN p_link ? 'status' THEN
                p_link ->> 'status'
            ELSE
                link.status
            END,
            actions = CASE WHEN p_link ? 'actions' THEN
                p_link -> 'actions'
            ELSE
                link.actions
            END,
            meta = CASE WHEN p_link ? 'meta' THEN
                p_link -> 'meta'
            ELSE
                link.meta
            END,
            source_url = CASE WHEN p_link ? 'source_url' THEN
                p_link ->> 'source_url'
            ELSE
                link.source_url
            END,
            updated_by = CASE WHEN p_link ? 'updated_by' THEN
                (p_link ->> 'updated_by')::integer
            ELSE
                link.updated_by
            END,
            sync_depth = CASE WHEN p_link ? 'sync_depth' THEN
                (p_link ->> 'sync_depth')::smallint
            ELSE
                link.sync_depth
            END,
            source = COALESCE(v_source, link.source),
            source_priority_root = COALESCE(v_source_priority_root, link.source_priority_root),
            created_by = v_created_by,
            twist_id = v_twist_id,
            -- Keep existing thread_id on update to prevent race conditions
            -- where concurrent saveLink calls create orphaned threads
            thread_id = link.thread_id,
            merged_from_thread_id = CASE WHEN p_link ? 'merged_from_thread_id' THEN
                (p_link ->> 'merged_from_thread_id')::uuid
            ELSE
                link.merged_from_thread_id
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
