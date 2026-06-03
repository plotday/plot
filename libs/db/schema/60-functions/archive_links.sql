-- Archive links from the given twist_instance (p_created_by) that match the
-- filter, and, for each affected thread, mark the twist_instance OWNER's
-- thread_priority row as archived — a PER-USER archive.
--
-- Removal strategy (see docs/superpowers/specs/2026-06-02-link-removal-sync-design.md):
--   * HARD-delete when the client has an independent bulk delete signal:
--     - whole-instance removal (uninstall): caller passes p_hard = true and
--       archives the twist_instance (the client observes archived_at).
--     - channel removal: the channel's `enabled` flag is already false (the
--       client observes it via user.channel).
--   * SOFT-delete (set archived_at) otherwise (item-specific meta/type/status
--     on a live instance + enabled channel) — delivered to the owner per-link
--     via user.link_redacted; the client hard-deletes it.
-- p_hard overrides the derivation when not NULL.
--
-- Returns affected priority IDs for sync notification.
CREATE OR REPLACE FUNCTION public.archive_links (
    p_created_by uuid,
    p_filter jsonb DEFAULT '{}' ::jsonb,
    p_hard boolean DEFAULT NULL
) RETURNS uuid[]
    LANGUAGE plpgsql
    AS $function$
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
$function$;
