-- Seed thread.topic from link's connector channel on connector-created links
-- so sibling threads from the same channel share a stable routing key.
--
-- Connectors call plot.createLink which creates the thread first (no links
-- attached yet, so upsert_thread cannot derive a channel: default) and then
-- inserts the link row carrying channel_id. Without a topic, one explicit
-- user move has no way to carry other threads from the same channel along:
-- the cascade's topic-shortcircuit matches NULL against NULL, and the bulk
-- mark_reclassify_candidates helper has no indexed candidate set to draw
-- from.
--
-- This trigger closes that gap by stamping thread.topic with
-- 'channel:<channel.id>' — channel.id is the bigint primary key, unique
-- across all connectors, accounts, and external channel ids.
--
-- Once the topic is set we mark every non-sticky thread_priority row for
-- the thread pending so the consumer Worker re-classifies it with the
-- now-available topic signal. The API path that wrote the link is
-- responsible for enqueueing ClassifyJobs for each marked row (see
-- workers/api/src/state/classify-thread.ts dispatchPendingForThread).
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

    -- Mark every non-sticky settled row pending. Pending rows (priority_id
    -- IS NULL) are already pending; sticky rows (user_moved = TRUE) are
    -- never reclassified.
    UPDATE public.thread_priority
    SET classify_at = now()
    WHERE thread_id = NEW.thread_id
      AND priority_id IS NOT NULL
      AND user_moved = FALSE;

    RETURN NEW;
END;
$$;

CREATE TRIGGER set_thread_topic_from_link_channel
    AFTER INSERT OR UPDATE OF channel_id, thread_id
    ON public.link
    FOR EACH ROW
    EXECUTE FUNCTION public.set_thread_topic_from_link_channel ();
