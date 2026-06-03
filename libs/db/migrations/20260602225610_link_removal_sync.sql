-- Drop index "link_source_priority_unique" from table: "link"
DROP INDEX "public"."link_source_priority_unique";
-- Modify "link" table
ALTER TABLE "public"."link" ADD COLUMN "archived_at" timestamptz NULL;
-- Create index "link_source_priority_unique" to table: "link"
CREATE UNIQUE INDEX "link_source_priority_unique" ON "public"."link" ("source", "source_priority_root") WHERE (archived_at IS NULL);
-- Create index "idx_link_archived_at" to table: "link"
CREATE INDEX "idx_link_archived_at" ON "public"."link" ("archived_at") WHERE (archived_at IS NOT NULL);
-- Create trigger "maybe_archive_thread_after_link_soft_delete"
CREATE TRIGGER "maybe_archive_thread_after_link_soft_delete" AFTER UPDATE OF "archived_at" ON "public"."link" FOR EACH ROW WHEN ((new.archived_at IS NOT NULL) AND (old.archived_at IS NULL)) EXECUTE FUNCTION "public"."maybe_archive_thread_last_holder"();
-- Modify "maybe_archive_thread_last_holder" function
CREATE OR REPLACE FUNCTION "public"."maybe_archive_thread_last_holder" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_thread_id uuid;
BEGIN
    v_thread_id := CASE TG_OP
        WHEN 'DELETE' THEN OLD.thread_id
        ELSE NEW.thread_id
    END;

    IF v_thread_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- If the thread already has a global archived_at, nothing to do.
    IF EXISTS (
        SELECT 1 FROM public.thread t
        WHERE t.id = v_thread_id AND t.archived_at IS NOT NULL
    ) THEN
        RETURN NULL;
    END IF;

    -- Active thread_priority rows?
    IF EXISTS (
        SELECT 1 FROM public.thread_priority tp
        WHERE tp.thread_id = v_thread_id
          AND tp.archived_at IS NULL
    ) THEN
        RETURN NULL;
    END IF;

    -- Any remaining LIVE links pointing at this thread? (Soft-deleted links
    -- count as absent so a per-item soft-delete can archive an emptied thread.)
    IF EXISTS (
        SELECT 1 FROM public.link l
        WHERE l.thread_id = v_thread_id
          AND l.archived_at IS NULL
    ) THEN
        RETURN NULL;
    END IF;

    UPDATE public.thread t
    SET archived_at = now()
    WHERE t.id = v_thread_id
      AND t.archived_at IS NULL;

    RETURN NULL;
END;
$$;
-- Create "archive_links" function
CREATE FUNCTION "public"."archive_links" ("p_created_by" uuid, "p_filter" jsonb DEFAULT '{}', "p_hard" boolean DEFAULT NULL::boolean) RETURNS uuid[] LANGUAGE plpgsql AS $$
DECLARE
    v_owner_user_id uuid;
    v_affected_priority_ids uuid[];
    v_now timestamptz := now();
    v_hard boolean;
    v_link_ids uuid[];
BEGIN
    SELECT owner_id INTO v_owner_user_id
    FROM public.twist_instance
    WHERE id = p_created_by;

    IF v_owner_user_id IS NULL THEN
        RETURN ARRAY[]::uuid[];
    END IF;

    -- Decide hard vs soft delete.
    v_hard := COALESCE(
        p_hard,
        CASE
            WHEN p_filter ? 'channelId' THEN
                -- Channel removal: hard only if the channel is confirmed disabled.
                NOT COALESCE((
                    SELECT c.enabled FROM public.channel c
                    WHERE c.twist_instance_id = p_created_by
                      AND c.channel_id = (p_filter ->> 'channelId')
                ), TRUE)
            WHEN p_filter = '{}'::jsonb THEN
                -- Whole-instance removal (uninstall). Caller should also pass
                -- p_hard = true; defaulting to hard is safe because the empty
                -- filter is only ever used by the uninstall path.
                TRUE
            ELSE
                FALSE
        END
    );

    -- Identify matching LIVE links once.
    SELECT ARRAY(
        SELECT l.id
        FROM public.link l
        WHERE l.created_by = p_created_by
          AND l.thread_id IS NOT NULL
          AND l.archived_at IS NULL
          AND (NOT (p_filter ? 'channelId') OR l.channel_id = (p_filter ->> 'channelId'))
          AND (NOT (p_filter ? 'type')      OR l.type = (p_filter ->> 'type'))
          AND (NOT (p_filter ? 'status')    OR l.status = (p_filter ->> 'status'))
          AND (NOT (p_filter ? 'meta')      OR l.meta @> (p_filter -> 'meta'))
    ) INTO v_link_ids;

    IF array_length(v_link_ids, 1) IS NULL THEN
        RETURN ARRAY[]::uuid[];
    END IF;

    -- Per-user archive: retire the owner's filing only on threads where this
    -- twist_instance has NO remaining unmatched LIVE links.
    WITH threads_matched AS (
        SELECT DISTINCT l.thread_id
        FROM public.link l
        WHERE l.id = ANY (v_link_ids)
    ),
    threads_fully_matched AS (
        SELECT tm.thread_id
        FROM threads_matched tm
        WHERE NOT EXISTS (
            SELECT 1 FROM public.link other_l
            WHERE other_l.thread_id = tm.thread_id
              AND other_l.created_by = p_created_by
              AND other_l.archived_at IS NULL
              AND other_l.id <> ALL (v_link_ids)
        )
    ),
    archived_priorities AS (
        UPDATE public.thread_priority tp
        SET archived_at = v_now
        FROM threads_fully_matched tfm
        WHERE tp.thread_id = tfm.thread_id
          AND tp.user_id = v_owner_user_id
          AND tp.archived_at IS NULL
        RETURNING tp.priority_id
    )
    SELECT ARRAY(SELECT DISTINCT priority_id FROM archived_priorities)
    INTO v_affected_priority_ids;

    -- Remove the matched links.
    IF v_hard THEN
        DELETE FROM public.link WHERE id = ANY (v_link_ids);
    ELSE
        UPDATE public.link SET archived_at = v_now WHERE id = ANY (v_link_ids);
    END IF;

    RETURN COALESCE(v_affected_priority_ids, ARRAY[]::uuid[]);
END;
$$;
-- Modify "upsert_link" function
CREATE OR REPLACE FUNCTION "user"."upsert_link" ("user_id" uuid, "p_link" jsonb, "p_defaults" jsonb DEFAULT '{}') RETURNS "public"."link" LANGUAGE plpgsql AS $$
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
    v_role text;
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
        channel_id)
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
            COALESCE(p_link ->> 'channel_id', p_defaults ->> 'channel_id'))
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
            END
        RETURNING
            * INTO v_result;
    RETURN v_result;
END;
$$;
-- Modify "link" view
CREATE OR REPLACE VIEW "user"."link" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "channel_id",
  "logo",
  "priority_id",
  "merged_from_thread_id",
  "priority_path",
  "revoked"
) AS SELECT COALESCE(tp.user_id, p.user_id) AS user_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.seq,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.channel_id,
    l.logo,
    COALESCE("user".effective_priority_id(tp.priority_id, tp.user_id), l.priority_id) AS priority_id,
    l.merged_from_thread_id,
    COALESCE(upe.path, pp.path) AS priority_path,
    false AS revoked
   FROM public.link l
     LEFT JOIN public.twist_instance ti ON ti.id = l.created_by AND l.twist_id IS NOT NULL AND ti.archived_at IS NULL
     LEFT JOIN public.thread_priority tp ON tp.thread_id = l.thread_id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (l.twist_id IS NULL OR ti.owner_id = tp.user_id)
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id)
     LEFT JOIN public.priority pp ON pp.id = l.priority_id AND l.thread_id IS NULL
     LEFT JOIN public.priority p ON p.id = l.priority_id AND l.thread_id IS NULL
  WHERE l.archived_at IS NULL AND (tp.user_id IS NOT NULL OR p.user_id IS NOT NULL);
-- Create "link_redacted" view
CREATE VIEW "user"."link_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "channel_id",
  "logo",
  "priority_id",
  "merged_from_thread_id",
  "priority_path",
  "revoked"
) AS SELECT ti.owner_id AS user_id,
    l.id,
    l.created_at,
    l.archived_at AS updated_at,
    l.seq,
    l.thread_id,
    NULL::text AS source,
    l.source_created_at,
    NULL::uuid AS author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    NULL::text AS title,
    NULL::text AS preview,
    NULL::uuid AS assignee_id,
    NULL::text AS type,
    NULL::text AS status,
    NULL::jsonb AS actions,
    NULL::jsonb AS meta,
    NULL::text AS source_url,
    NULL::text AS channel_id,
    NULL::text AS logo,
    "user".effective_priority_id(tp.priority_id, ti.owner_id) AS priority_id,
    NULL::uuid AS merged_from_thread_id,
    upe.path AS priority_path,
    true AS revoked
   FROM public.link l
     JOIN public.twist_instance ti ON ti.id = l.created_by AND l.twist_id IS NOT NULL AND ti.archived_at IS NULL
     LEFT JOIN public.thread_priority tp ON tp.thread_id = l.thread_id AND tp.user_id = ti.owner_id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = ti.owner_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, ti.owner_id)
  WHERE l.archived_at IS NOT NULL;
-- Modify "schedule" view
CREATE OR REPLACE VIEW "user"."schedule" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "at",
  "on",
  "recurrence_rule",
  "duration",
  "recurrence_exdates",
  "occurrence",
  "thread_id",
  "link_id",
  "reason",
  "priority_path",
  "range_at",
  "range_on",
  "contacts"
) AS SELECT tp.user_id,
    s.id,
    s.created_at,
    s.updated_at,
    s.seq,
    COALESCE(s.archived_at, upe.archived_at) AS archived_at,
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    s.link_id,
    s.reason,
    upe.path AS priority_path,
        CASE
            WHEN s.at IS NOT NULL THEN s.at
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN s."on" IS NOT NULL THEN s."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', sc.id, 'contact_id', sc.contact_id, 'contact_email', c.email, 'contact_name', c.name, 'contact_user_id', c.user_id, 'status', sc.status, 'role', sc.role, 'archived_at', sc.archived_at, 'updated_at', sc.updated_at) ORDER BY sc.created_at) AS jsonb_agg
           FROM public.schedule_contact sc
             JOIN public.contact c ON c.id = sc.contact_id
          WHERE sc.schedule_id = s.id), '[]'::jsonb) AS contacts
   FROM public.schedule s
     LEFT JOIN public.link l ON l.id = s.link_id AND l.archived_at IS NULL
     LEFT JOIN public.twist_instance ti ON ti.id = l.created_by AND l.twist_id IS NOT NULL AND ti.archived_at IS NULL
     JOIN public.thread_priority tp ON tp.thread_id = COALESCE(s.thread_id, l.thread_id) AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (s.link_id IS NULL OR l.twist_id IS NULL OR ti.owner_id = tp.user_id)
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id);
-- Drop "archive_links" function
DROP FUNCTION "public"."archive_links" (uuid, jsonb);
