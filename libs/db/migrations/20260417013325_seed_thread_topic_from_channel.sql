-- Create "set_thread_topic_from_link_channel" function
CREATE FUNCTION "public"."set_thread_topic_from_link_channel" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.channel_id IS NULL OR NEW.thread_id IS NULL THEN
        RETURN NEW;
    END IF;

    UPDATE public.thread
    SET topic = 'channel:' || NEW.channel_id
    WHERE id = NEW.thread_id
      AND topic IS NULL;

    RETURN NEW;
END;
$$;
-- Create trigger "set_thread_topic_from_link_channel"
CREATE TRIGGER "set_thread_topic_from_link_channel" AFTER INSERT OR UPDATE OF "channel_id", "thread_id" ON "public"."link" FOR EACH ROW EXECUTE FUNCTION "public"."set_thread_topic_from_link_channel"();

-- Backfill existing threads with NULL topic from their earliest channel-linked
-- link. One row per thread via DISTINCT ON ordered by link.created_at so
-- threads spanning multiple channels (rare) get the first channel they landed in.
UPDATE public.thread t
SET topic = 'channel:' || l.channel_id
FROM (
    SELECT DISTINCT ON (thread_id) thread_id, channel_id
    FROM public.link
    WHERE channel_id IS NOT NULL
    ORDER BY thread_id, created_at ASC
) l
WHERE l.thread_id = t.id
  AND t.topic IS NULL;
