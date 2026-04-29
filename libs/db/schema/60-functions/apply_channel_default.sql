-- Re-file threads after a channel's default_priority_id has changed.
--
-- Called by the API after the ChannelRouter writes new defaults. Assumes
-- channel.default_priority_id has already been updated.
--
-- Candidate set for re-file:
--   (a) thread_priority rows currently tagged with
--       applied_default_channel_id = p_channel_id (previously placed by
--       this channel's default — may or may not still match).
--   (b) thread_priority rows sitting at the owner's root priority with
--       user_moved = FALSE whose thread.topic = 'channel:<p_channel_id>'.
--       This is the initial-adoption case: before the first default was
--       assigned, new threads piled up at root with no marker.
--
-- Rows with user_moved = TRUE are never touched. Only the channel owner's
-- rows are considered — peers' rows are filed via their own channel rules.
--
-- For each candidate, calls classify_thread_for_user to pick the new
-- priority (which consults the freshly-updated channel.default_priority_id
-- via its step 2.5 branch). Updates priority_id and stamps or clears
-- applied_default_channel_id so the tag stays consistent with whether the
-- row actually landed at the channel default.
--
-- Returns the number of rows moved (priority_id changed OR the tag flipped).
CREATE OR REPLACE FUNCTION public.apply_channel_default (p_channel_id bigint)
    RETURNS int
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_owner_id uuid;
    v_root_id uuid;
    v_updated int;
BEGIN
    SELECT ti.owner_id
    INTO v_owner_id
    FROM public.channel c
    JOIN public.twist_instance ti ON ti.id = c.twist_instance_id
    WHERE c.id = p_channel_id;

    IF v_owner_id IS NULL THEN
        RETURN 0;
    END IF;

    SELECT p.id INTO v_root_id
    FROM public.priority p
    WHERE p.user_id = v_owner_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    -- AS MATERIALIZED on both CTEs is load-bearing: classify_thread_for_user
    -- is STABLE, so without the fence the planner inlines `reclass` and
    -- pushes the outer `r.new_priority_id IS NOT NULL` filter into
    -- `candidates`'s thread_priority bitmap scan. That broadens the inner
    -- scan to every (user_id, priority_id=root) row instead of only
    -- candidates whose thread.topic matches this channel, and classify
    -- ends up called on every root-filed thread (≫ candidates). With the
    -- fence, candidates is computed once and classify is called exactly
    -- once per row. Reproduced 30s timeout vs. 47ms with materialization.
    WITH candidates AS MATERIALIZED (
        SELECT tp.thread_id, tp.user_id
        FROM public.thread_priority tp
        WHERE tp.applied_default_channel_id = p_channel_id
          AND tp.user_id = v_owner_id
          AND tp.user_moved = FALSE

        UNION

        SELECT tp.thread_id, tp.user_id
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.user_id = v_owner_id
          AND tp.user_moved = FALSE
          AND tp.priority_id = v_root_id
          AND t.topic = 'channel:' || p_channel_id::text
          AND t.archived_at IS NULL
    ),
    reclass AS MATERIALIZED (
        SELECT c.thread_id,
               c.user_id,
               public.classify_thread_for_user(c.user_id, c.thread_id) AS new_priority_id
        FROM candidates c
    ),
    updated AS (
        UPDATE public.thread_priority tp
        SET priority_id = r.new_priority_id,
            applied_default_channel_id = public.channel_default_marker (
                r.user_id, r.thread_id, r.new_priority_id
            ),
            updated_at = now()
        FROM reclass r
        WHERE tp.thread_id = r.thread_id
          AND tp.user_id = r.user_id
          AND tp.user_moved = FALSE
          AND r.new_priority_id IS NOT NULL
          AND (
              r.new_priority_id IS DISTINCT FROM tp.priority_id
              OR public.channel_default_marker (
                     r.user_id, r.thread_id, r.new_priority_id
                 ) IS DISTINCT FROM tp.applied_default_channel_id
          )
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_updated FROM updated;

    RETURN v_updated;
END;
$function$;

COMMENT ON FUNCTION public.apply_channel_default IS 'Re-file threads after a channel''s default_priority_id changes. Walks candidates tagged with applied_default_channel_id = p_channel_id plus root-filed threads whose topic matches this channel, re-runs classify_thread_for_user, and updates priority_id + applied_default_channel_id. Never touches rows with user_moved = TRUE.';
