-- Modify "archive_links" function
CREATE OR REPLACE FUNCTION "public"."archive_links" ("p_created_by" uuid, "p_filter" jsonb DEFAULT '{}', "p_hard" boolean DEFAULT NULL::boolean) RETURNS uuid[] LANGUAGE plpgsql AS $$
DECLARE
    v_owner_user_id uuid;
    v_affected_priority_ids uuid[];
    v_now timestamptz := now();
    v_link_ids uuid[];
BEGIN
    SELECT owner_id INTO v_owner_user_id
    FROM public.twist_instance
    WHERE id = p_created_by;

    IF v_owner_user_id IS NULL THEN
        RETURN ARRAY[]::uuid[];
    END IF;

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

    -- Remove the matched links — always soft-delete so each link emits a
    -- durable per-row tombstone via user.link_redacted (see header). The
    -- archived_at UPDATE bumps link.seq, so the seq cursor re-delivers the
    -- redacted stub until the client acks; the client then hard-deletes the
    -- link + its schedules locally.
    UPDATE public.link SET archived_at = v_now WHERE id = ANY (v_link_ids);

    RETURN COALESCE(v_affected_priority_ids, ARRAY[]::uuid[]);
END;
$$;
-- Modify "link_redacted" view
CREATE OR REPLACE VIEW "user"."link_redacted" (
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
  "priority",
  "note_scoped",
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
    l.priority,
    l.note_scoped,
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
     JOIN public.twist_instance ti ON ti.id = l.created_by AND l.twist_id IS NOT NULL
     LEFT JOIN public.thread_priority tp ON tp.thread_id = l.thread_id AND tp.user_id = ti.owner_id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = ti.owner_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, ti.owner_id)
  WHERE l.archived_at IS NOT NULL;
