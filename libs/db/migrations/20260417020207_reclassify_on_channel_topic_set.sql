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

    -- prepareThreadForDb classifies the new thread before the link row exists,
    -- so the topic short-circuit had nothing to match. Now that topic is set,
    -- re-classify any thread_priority row that the user has not explicitly
    -- moved. user_moved = TRUE rows are sticky and are never overwritten.
    UPDATE public.thread_priority tp
    SET priority_id = public.classify_thread_for_user(tp.user_id, NEW.thread_id),
        updated_at = now()
    WHERE tp.thread_id = NEW.thread_id
      AND tp.user_moved = FALSE
      AND public.classify_thread_for_user(tp.user_id, NEW.thread_id)
          IS DISTINCT FROM tp.priority_id;

    RETURN NEW;
END;
$$;

-- Re-file existing thread_priority rows that classified before the topic was
-- set on their thread. Touches only rows where the user has not explicitly
-- moved the thread and where classify now returns a different priority.
UPDATE public.thread_priority tp
SET priority_id = public.classify_thread_for_user(tp.user_id, tp.thread_id),
    updated_at = now()
FROM public.thread t
WHERE tp.thread_id = t.id
  AND tp.user_moved = FALSE
  AND t.topic IS NOT NULL
  AND t.archived_at IS NULL
  AND public.classify_thread_for_user(tp.user_id, tp.thread_id)
      IS DISTINCT FROM tp.priority_id;
