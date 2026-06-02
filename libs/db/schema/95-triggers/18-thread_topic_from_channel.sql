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
-- Once the topic is FIRST set we mark every non-sticky thread_priority row
-- for the thread pending so the consumer Worker re-classifies it with the
-- now-available topic signal. The API path that wrote the link is
-- responsible for enqueueing ClassifyJobs for each marked row (see
-- workers/api/src/state/classify-thread.ts dispatchPendingForThread).
--
-- LOCK ORDER INVARIANT — DO NOT BREAK:
--   The thread_priority UPDATE below is gated on `IF FOUND` so it runs
--   ONLY when the preceding thread UPDATE actually transitioned the topic
--   from NULL to 'channel:...'. Without the gate, every link insert on an
--   already-classified thread runs an UPDATE thread_priority that DOES
--   NOT first lock the parent thread row (the gating UPDATE matched 0
--   rows). That inverts the lock order used by "user".upsert_thread on
--   its UPDATE path, which acquires:
--      thread row → user_sync (via the FOR EACH STATEMENT
--      sync_user_for_thread trigger fired by thread UPDATE)
--      → thread_priority (line 528 INSERT).
--   The ungated trigger acquires:
--      thread_priority (UPDATE) → user_sync (via
--      sync_user_for_thread_priority FOR EACH STATEMENT).
--   Two concurrent transactions hitting the same thread T then deadlock on
--   (thread_priority, user_sync) — see the postgres server log for
--   "deadlock detected" dumps showing upsert_thread blocked at line 528
--   INSERT thread_priority while upsert_link was blocked inserting
--   user_sync inside this trigger's sync_user_for_thread_priority chain.
--
-- When topic is already set (the common case on every link beyond the
-- first), the gate causes this trigger to be a complete no-op for that
-- thread — which is also semantically right (already classified). The
-- first-link case still acquires both locks, but in the same order as
-- upsert_thread (thread row first, since the inner UPDATE thread DID
-- match), so the cycle is impossible.
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

    -- Gate on FOUND so this only fires when the topic was JUST set
    -- (transition NULL → 'channel:...'). See the LOCK ORDER INVARIANT
    -- block above before removing or weakening this guard.
    IF FOUND THEN
        -- Mark every non-sticky settled row pending. Pending rows
        -- (priority_id IS NULL) are already pending; sticky rows
        -- (user_moved = TRUE) are never reclassified.
        UPDATE public.thread_priority
        SET classify_at = now()
        WHERE thread_id = NEW.thread_id
          AND priority_id IS NOT NULL
          AND user_moved = FALSE;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER set_thread_topic_from_link_channel
    AFTER INSERT OR UPDATE OF channel_id, thread_id
    ON public.link
    FOR EACH ROW
    EXECUTE FUNCTION public.set_thread_topic_from_link_channel ();
