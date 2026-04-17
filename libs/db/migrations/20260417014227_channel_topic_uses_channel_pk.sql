-- Modify "set_thread_topic_from_link_channel" function
CREATE OR REPLACE FUNCTION "public"."set_thread_topic_from_link_channel" () RETURNS trigger LANGUAGE plpgsql AS $$
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

    RETURN NEW;
END;
$$;

-- Re-backfill thread.topic to 'channel:<channel.id>' (bigint PK, globally
-- unique) instead of the previous 'channel:<external_channel_id>' which
-- would collide across connectors and accounts sharing an id like 'STARRED'.
-- Walks every link that still has a channel_id, resolves the channel PK via
-- the link's twist_instance_id (link.created_by), and overwrites any
-- 'channel:' topic on the linked thread. Leaves non-'channel:' topics alone.
UPDATE public.thread t
SET topic = 'channel:' || ch.id
FROM (
    SELECT DISTINCT ON (l.thread_id)
           l.thread_id,
           ch.id
    FROM public.link l
    JOIN public.channel ch
      ON ch.twist_instance_id = l.created_by
     AND ch.channel_id = l.channel_id
    WHERE l.channel_id IS NOT NULL
      AND l.thread_id IS NOT NULL
    ORDER BY l.thread_id, l.created_at ASC
) ch
WHERE ch.thread_id = t.id
  AND (t.topic IS NULL OR t.topic LIKE 'channel:%');
