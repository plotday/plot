-- Seed thread.topic from link's connector channel on connector-created links
-- so sibling threads from the same channel share a stable routing key.
--
-- Connectors call plot.createLink which creates the thread first (no links
-- attached yet, so upsert_thread cannot derive a channel: default) and then
-- inserts the link row carrying channel_id. Without a topic, one explicit
-- user move has no way to carry other threads from the same channel along:
-- classify_thread_for_user's topic filter matches NULL against NULL, and
-- reclassify_user_threads has no indexed candidate set to draw from.
--
-- This trigger closes that gap by stamping thread.topic with
-- 'channel:<channel.id>' — channel.id is the bigint primary key, unique
-- across all connectors, accounts, and external channel ids. link.channel_id
-- is the external text id and is only unique within a twist_instance, so we
-- resolve it through the channel table to avoid collisions across
-- connections. Respects an explicit non-NULL topic set by the caller — only
-- fills NULLs.
CREATE OR REPLACE FUNCTION public.set_thread_topic_from_link_channel ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_channel_pk bigint;
BEGIN
    IF NEW.channel_id IS NULL OR NEW.thread_id IS NULL OR NEW.created_by IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT ch.id INTO v_channel_pk
    FROM public.channel ch
    WHERE ch.twist_instance_id = NEW.created_by
      AND ch.channel_id = NEW.channel_id
    LIMIT 1;

    IF v_channel_pk IS NULL THEN
        RETURN NEW;
    END IF;

    UPDATE public.thread
    SET topic = 'channel:' || v_channel_pk
    WHERE id = NEW.thread_id
      AND topic IS NULL;

    -- prepareThreadForDb classifies the new thread before the link row exists,
    -- so the topic short-circuit had nothing to match. Now that topic is set,
    -- re-classify any thread_priority row that the user has not explicitly
    -- moved. user_moved = TRUE rows are sticky and are never overwritten.
    -- Also stamp applied_default_channel_id when the new priority matches
    -- this channel's default — the marker lets apply_channel_default find
    -- the row later when the default changes again.
    UPDATE public.thread_priority tp
    SET priority_id = classified.new_priority_id,
        applied_default_channel_id = public.channel_default_marker (
            tp.user_id, NEW.thread_id, classified.new_priority_id
        ),
        updated_at = now()
    FROM (
        SELECT
            tp2.user_id,
            tp2.thread_id,
            tp2.priority_id AS current_priority_id,
            tp2.applied_default_channel_id AS current_marker,
            public.classify_thread_for_user(tp2.user_id, NEW.thread_id) AS new_priority_id
        FROM public.thread_priority tp2
        WHERE tp2.thread_id = NEW.thread_id
          AND tp2.user_moved = FALSE
    ) classified
    WHERE tp.thread_id = classified.thread_id
      AND tp.user_id = classified.user_id
      AND tp.user_moved = FALSE
      AND (
          classified.new_priority_id IS DISTINCT FROM classified.current_priority_id
          OR public.channel_default_marker (
                 tp.user_id, NEW.thread_id, classified.new_priority_id
             ) IS DISTINCT FROM classified.current_marker
      );

    RETURN NEW;
END;
$$;

CREATE TRIGGER set_thread_topic_from_link_channel
    AFTER INSERT OR UPDATE OF channel_id, thread_id
    ON public.link
    FOR EACH ROW
    EXECUTE FUNCTION public.set_thread_topic_from_link_channel ();
