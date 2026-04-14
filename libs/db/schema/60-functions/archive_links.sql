-- Archive links from the given twist_instance (p_created_by) that match the
-- filter, and, for each affected thread, mark the twist_instance OWNER's
-- thread_priority row as archived — a PER-USER archive. The thread itself
-- is only globally archived by the last_holder_archive_thread trigger when
-- no active thread_priority rows and no active links remain.
--
-- Semantics:
--   - Identify links created by p_created_by (a twist_instance) matching
--     the filter.
--   - For each thread these links touch, if this twist_instance has NO
--     OTHER links on that thread outside the filter, archive the owner
--     user's thread_priority row for that thread.
--   - Link rows themselves are deleted (matching the prior behaviour, which
--     is now explicit rather than implicit via thread archival cascade).
--
-- Returns affected priority IDs for sync notification.
CREATE OR REPLACE FUNCTION public.archive_links (
    p_created_by uuid,
    p_filter jsonb DEFAULT '{}' ::jsonb
) RETURNS uuid[]
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_owner_user_id uuid;
    v_affected_priority_ids uuid[];
    v_now timestamptz := now();
BEGIN
    -- Resolve the user who owns this twist_instance. All archive effects
    -- apply only to this user.
    SELECT owner_id INTO v_owner_user_id
    FROM public.twist_instance
    WHERE id = p_created_by;

    IF v_owner_user_id IS NULL THEN
        RETURN ARRAY[]::uuid[];
    END IF;

    WITH matched_links AS (
        SELECT l.id AS link_id, l.thread_id
        FROM public.link l
        WHERE l.created_by = p_created_by
          AND l.thread_id IS NOT NULL
          AND (NOT (p_filter ? 'channelId')
               OR l.channel_id = (p_filter ->> 'channelId'))
          AND (NOT (p_filter ? 'type')
               OR l.type = (p_filter ->> 'type'))
          AND (NOT (p_filter ? 'status')
               OR l.status = (p_filter ->> 'status'))
          AND (NOT (p_filter ? 'meta')
               OR l.meta @> (p_filter -> 'meta'))
    ),
    -- For per-user archive we only want to retire the user's filing on
    -- threads where this twist_instance has no remaining unmatched links.
    -- (If the filter excluded some of its links, the user's connector still
    -- actively contributes to the thread, so don't archive their filing.)
    threads_fully_matched AS (
        SELECT DISTINCT ml.thread_id
        FROM matched_links ml
        WHERE NOT EXISTS (
            SELECT 1 FROM public.link other_l
            WHERE other_l.thread_id = ml.thread_id
              AND other_l.created_by = p_created_by
              AND other_l.id NOT IN (SELECT link_id FROM matched_links)
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
    ),
    -- Delete the link rows we just archived at the thread_priority level.
    deleted_links AS (
        DELETE FROM public.link l
        USING matched_links ml
        WHERE l.id = ml.link_id
        RETURNING l.id
    )
    SELECT ARRAY(SELECT DISTINCT priority_id FROM archived_priorities)
    INTO v_affected_priority_ids;

    RETURN COALESCE(v_affected_priority_ids, ARRAY[]::uuid[]);
END;
$function$;
