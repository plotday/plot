-- Drop "thread_x" view
DROP VIEW "public"."thread_x";
-- Modify "thread" table
ALTER TABLE "public"."thread" ADD COLUMN "dropped_contacts" uuid[] NULL DEFAULT ARRAY[]::uuid[];
-- Set comment to column: "dropped_contacts" on table: "thread"
COMMENT ON COLUMN "public"."thread"."dropped_contacts" IS 'Contacts who have been dropped from the active recipient set by the message-mode heuristic. Every uuid here MUST also appear in contacts (invariant enforced by update_thread_dropped_contacts). Dropped contacts retain thread visibility but are excluded from outbound defaults and the active-participants display.';
-- Create "update_thread_dropped_contacts" function
CREATE FUNCTION "public"."update_thread_dropped_contacts" ("p_thread_id" uuid, "p_drop" uuid[] DEFAULT ARRAY[]::uuid[], "p_undrop" uuid[] DEFAULT ARRAY[]::uuid[]) RETURNS void LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_current_contacts uuid[];
    v_current_dropped uuid[];
    v_new_dropped uuid[];
    v_current_meta jsonb;
    v_new_meta jsonb;
    v_contact_id uuid;
BEGIN
    -- Early exit when nothing to do.
    IF (p_drop IS NULL OR cardinality(p_drop) = 0)
        AND (p_undrop IS NULL OR cardinality(p_undrop) = 0) THEN
        RETURN;
    END IF;

    -- Fetch current state.
    SELECT contacts, dropped_contacts, contact_meta
      INTO v_current_contacts, v_current_dropped, v_current_meta
    FROM thread
    WHERE id = p_thread_id;

    -- Thread doesn't exist — nothing to do.
    IF v_current_contacts IS NULL THEN
        RETURN;
    END IF;
    IF v_current_dropped IS NULL THEN
        v_current_dropped := ARRAY[]::uuid[];
    END IF;
    IF v_current_meta IS NULL THEN
        v_current_meta := '{}'::jsonb;
    END IF;

    -- Compute new_dropped = (current_dropped ∪ p_drop) - p_undrop.
    -- Only include IDs in p_drop that are actually in contacts (invariant).
    SELECT COALESCE(array_agg(DISTINCT cid ORDER BY cid), ARRAY[]::uuid[])
      INTO v_new_dropped
    FROM (
        -- Existing dropped contacts not being undropped
        SELECT unnest AS cid
        FROM unnest(v_current_dropped)
        WHERE p_undrop IS NULL OR NOT (unnest = ANY(p_undrop))
        UNION
        -- New drops: only include IDs already in contacts
        SELECT unnest AS cid
        FROM unnest(p_drop)
        WHERE p_drop IS NOT NULL
          AND unnest = ANY(v_current_contacts)
          AND (p_undrop IS NULL OR NOT (unnest = ANY(p_undrop)))
    ) sub;

    -- Strip contact_meta entries for p_drop (they no longer have an active role).
    v_new_meta := v_current_meta;
    IF p_drop IS NOT NULL THEN
        FOREACH v_contact_id IN ARRAY p_drop LOOP
            v_new_meta := v_new_meta - (v_contact_id::text);
        END LOOP;
    END IF;

    -- No-op if nothing actually changed.
    IF v_new_dropped IS NOT DISTINCT FROM v_current_dropped
        AND v_new_meta IS NOT DISTINCT FROM v_current_meta THEN
        RETURN;
    END IF;

    -- Update thread. Fires the existing seq/updated_at trigger so clients
    -- re-sync and see the changed dropped_contacts array.
    -- Does NOT modify contacts — dropped contacts keep thread visibility.
    UPDATE thread
       SET dropped_contacts = v_new_dropped,
           contact_meta = v_new_meta
     WHERE id = p_thread_id;
END;
$$;
-- Set comment to function: "update_thread_dropped_contacts"
COMMENT ON FUNCTION "public"."update_thread_dropped_contacts" IS 'Privileged management of the dropped_contacts set on a message-mode thread, intended for platform use only (see workers/api/src/twist/tools/plot/link.ts). Dropped contacts remain in thread.contacts (for visibility) but are excluded from the active recipient set. p_drop appends IDs (deduplicated, constrained to existing contacts); p_undrop removes IDs. Bypasses share_thread''s user access-control check.';
-- Create "thread_x" view
CREATE VIEW "public"."thread_x" (
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "archived_at",
  "draft",
  "contacts",
  "dropped_contacts",
  "title",
  "preview",
  "last_note_created_at",
  "sync_depth",
  "last_note_source_created_at",
  "key",
  "icon",
  "groups",
  "topic",
  "embedding",
  "twist_id",
  "pending_contacts",
  "contact_meta",
  "seq",
  "last_note_seq",
  "merged_into_thread_id"
) AS SELECT id,
    created_at,
    updated_at,
    created_by,
    updated_by,
    archived_at,
    draft,
    contacts,
    dropped_contacts,
    title,
    preview,
    last_note_created_at,
    sync_depth,
    last_note_source_created_at,
    key,
    icon,
    groups,
    topic,
    embedding,
    twist_id,
    pending_contacts,
    contact_meta,
    seq,
    last_note_seq,
    merged_into_thread_id
   FROM public.thread a;
-- Modify "note_redacted" view
CREATE OR REPLACE VIEW "user"."note_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "mentions",
  "re_note_id",
  "merged_from_thread_id"
) AS SELECT tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    NULL::uuid[] AS access_contacts,
    NULL::text AS content,
    NULL::jsonb AS actions,
    NULL::uuid[] AS mentions,
    n.re_note_id,
    n.merged_from_thread_id
   FROM public.note n
     JOIN public.thread a ON a.id = n.thread_id
     JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
  WHERE (n.draft = false OR n.created_by = tp.user_id) AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id)) AND n.access_contacts IS NOT NULL AND n.created_by <> tp.user_id AND NOT COALESCE(n.access_contacts, ARRAY[]::uuid[]) && "user".user_contact_ids(tp.user_id) AND NOT (a.dropped_contacts IS NOT NULL AND cardinality(a.dropped_contacts) > 0 AND a.dropped_contacts && "user".user_contact_ids(tp.user_id));
-- Drop "prune_thread_contacts" function
DROP FUNCTION "public"."prune_thread_contacts";
