-- Upsert link with smart handling
-- On INSERT: Infers required fields from defaults if provided
-- On UPDATE: Only updates fields whose keys are present in p_link
--   - Key absent: keep existing value
--   - Key present (even with null): use provided value (allows clearing to NULL)
-- Derivation: Automatically derives source_priority_root and twist_id
--
-- Parameters:
--   p_link: link data as JSONB (explicitly provided values only)
--   p_defaults: default values as JSONB (all fields with defaults - used on INSERT if not in p_link)
--
-- Returns: The full link row
CREATE OR REPLACE FUNCTION "user".upsert_link (user_id uuid, p_link jsonb, p_defaults jsonb DEFAULT '{}' ::jsonb)
    RETURNS link
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_result link;
    v_id uuid;
    v_thread_id uuid;
    v_source text;
    v_sources text[];
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
    -- Derive canonical sources array: prefer explicit `sources`, else fall back
    -- to the legacy [source, related_source] pair (deduped, non-null, sorted
    -- for deterministic ordering across users).
    IF p_link ? 'sources' THEN
        v_sources := ARRAY(SELECT DISTINCT s FROM jsonb_array_elements_text(p_link -> 'sources') s WHERE s IS NOT NULL AND s <> '' ORDER BY s);
    ELSIF p_defaults ? 'sources' THEN
        v_sources := ARRAY(SELECT DISTINCT s FROM jsonb_array_elements_text(p_defaults -> 'sources') s WHERE s IS NOT NULL AND s <> '' ORDER BY s);
    ELSE
        v_sources := ARRAY(
            SELECT DISTINCT s FROM UNNEST(ARRAY[
                v_source,
                p_link ->> 'related_source',
                p_defaults ->> 'related_source'
            ]) s WHERE s IS NOT NULL AND s <> '' ORDER BY s
        );
    END IF;
    -- Keep legacy `source` populated from the first (alphabetically smallest)
    -- element if absent, so the (source, source_priority_root) unique
    -- constraint and ON CONFLICT path continue to work. The sort guarantees
    -- two users emitting the same sources set compute the same legacy source.
    IF v_source IS NULL AND cardinality(v_sources) > 0 THEN
        v_source := v_sources[1];
    END IF;
    v_created_by := COALESCE((p_link ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);
    v_author_id := COALESCE((p_link ->> 'author_id')::uuid, (p_defaults ->> 'author_id')::uuid, v_created_by);

    -- DERIVE source_priority_root if explicitly provided
    IF p_link ? 'source_priority_root' AND (p_link ->> 'source_priority_root') IS NOT NULL THEN
        v_source_priority_root := (p_link ->> 'source_priority_root')::ltree;
    END IF;

    -- Generate id if not provided
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

    -- Look up the calling user's priority for this thread and derive source_priority_root
    SELECT
        tp.priority_id,
        CASE WHEN v_source_priority_root IS NULL AND v_source IS NOT NULL
            THEN subpath(p.path, 0, 1)
            ELSE v_source_priority_root
        END
    INTO v_priority_id, v_source_priority_root
    FROM
        thread_priority tp
        JOIN priority p ON p.id = tp.priority_id
    WHERE
        tp.thread_id = v_thread_id
        AND tp.user_id = upsert_link.user_id;

    IF v_priority_id IS NULL THEN
        -- Check if the thread exists at all
        IF NOT EXISTS (SELECT 1 FROM thread WHERE id = v_thread_id) THEN
            RAISE EXCEPTION 'Thread not found';
        END IF;
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;
    IF NOT user_has_priority_access(upsert_link.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;

    -- For existing links, preserve the original created_by (any priority member
    -- can update link fields like assignee_id without owning the creator entity).
    -- For new links, validate that created_by is the user or their owned twist.
    -- Single query instead of EXISTS + separate SELECT
    DECLARE
        v_existing_created_by uuid;
    BEGIN
        SELECT l.created_by INTO v_existing_created_by FROM link l WHERE l.id = v_id;
        IF v_existing_created_by IS NOT NULL THEN
            v_created_by := v_existing_created_by;
        ELSE
            IF v_created_by IS DISTINCT FROM user_id THEN
                IF NOT EXISTS (
                    SELECT
                        1
                    FROM
                        twist_instance pt
                    WHERE
                        pt.id = v_created_by
                        AND pt.owner_id = upsert_link.user_id) THEN
                    RAISE EXCEPTION 'created_by must be user or owned twist_instance';
                END IF;
            END IF;
        END IF;
    END;

    -- DERIVE twist_id from created_by (twist_instance_id)
    IF p_link ? 'twist_id' AND (p_link ->> 'twist_id') IS NOT NULL THEN
        v_twist_id := (p_link ->> 'twist_id')::bigint;
    ELSIF v_created_by IS NOT NULL THEN
        SELECT
            pt.twist_id INTO v_twist_id
        FROM
            twist_instance pt
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
    INSERT INTO link (id, thread_id, source, sources, source_created_at, author_id, twist_id,
        created_by, updated_by, sync_depth, title, preview, assignee_id, type, status,
        actions, meta, source_url, merged_from_thread_id, related_source,
        channel_id, supports_assignee, priority, note_scoped)
        VALUES (v_id, v_thread_id, v_source, v_sources,
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
            COALESCE((p_link ->> 'merged_from_thread_id')::uuid, (p_defaults ->> 'merged_from_thread_id')::uuid),
            COALESCE(p_link ->> 'related_source', p_defaults ->> 'related_source'),
            COALESCE(p_link ->> 'channel_id', p_defaults ->> 'channel_id'),
            (v_assignee_id IS NOT NULL)
        , COALESCE((p_link ->> 'priority')::integer, (p_defaults ->> 'priority')::integer, 0)
        , COALESCE((p_link ->> 'note_scoped')::boolean, (p_defaults ->> 'note_scoped')::boolean, false))
    ON CONFLICT (source, source_priority_root) WHERE archived_at IS NULL
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
                COALESCE(link.meta, '{}'::jsonb) || (p_link -> 'meta')
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
            -- Union new sources with existing (dedupe, sort). Preserves
            -- aliases other connectors may have already attached.
            sources = ARRAY(
                SELECT DISTINCT s FROM UNNEST(link.sources || v_sources) s
                WHERE s IS NOT NULL AND s <> ''
                ORDER BY s
            ),
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
            END,
            related_source = CASE WHEN p_link ? 'related_source' THEN
                p_link ->> 'related_source'
            ELSE
                link.related_source
            END,
            channel_id = CASE WHEN p_link ? 'channel_id' THEN
                p_link ->> 'channel_id'
            ELSE
                link.channel_id
            END,
            -- Sticky: once true, stays true. Flips true the first time an
            -- assignee is written (only assignment-capable connectors do).
            supports_assignee = link.supports_assignee
                OR (CASE WHEN p_link ? 'assignee_id' THEN
                        (p_link ->> 'assignee_id')::uuid
                    ELSE
                        COALESCE(v_assignee_id, link.assignee_id)
                    END) IS NOT NULL
            ,
            priority = CASE WHEN p_link ? 'priority' THEN
                (p_link ->> 'priority')::integer
            ELSE
                link.priority
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$function$;
