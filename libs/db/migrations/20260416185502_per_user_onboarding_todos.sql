-- Create "file_onboarding_todos" function
CREATE FUNCTION "public"."file_onboarding_todos" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_thread_key text;
    v_contact_id uuid;
BEGIN
    -- Escape hatch for repair migrations.
    IF current_setting('plot.skip_onboarding_todos', true) = 'true' THEN
        RETURN NEW;
    END IF;

    SELECT key INTO v_thread_key FROM public.thread WHERE id = NEW.thread_id;
    IF v_thread_key NOT IN ('priorities', 'connections', 'twists', 'notifications') THEN
        RETURN NEW;
    END IF;

    -- Use the user's primary linked contact as the actor — same actor used
    -- elsewhere for per-user task ownership (see recompute_outstanding_tasks).
    SELECT uc.contact_id INTO v_contact_id
    FROM public.user_contact uc
    WHERE uc.user_id = NEW.user_id
      AND uc."primary" = TRUE
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL
    LIMIT 1;

    IF v_contact_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- ON CONFLICT DO NOTHING preserves prior decisions: if the user previously
    -- had this Todo and archived it (with or without marking Done), we leave
    -- the archived row alone instead of resurrecting it.
    INSERT INTO public.note_tag (actor_id, note_id, tag_id)
    SELECT v_contact_id, n.id, 1
    FROM public.note n
    WHERE n.thread_id = NEW.thread_id
      AND n.key = 'todo'
      AND n.archived_at IS NULL
    ON CONFLICT (actor_id, note_id, tag_id) DO NOTHING;

    PERFORM public.recompute_outstanding_tasks(NEW.thread_id, NEW.user_id);

    RETURN NEW;
END;
$$;
-- Create trigger "file_onboarding_todos"
CREATE TRIGGER "file_onboarding_todos" AFTER INSERT ON "public"."thread_priority" FOR EACH ROW EXECUTE FUNCTION "public"."file_onboarding_todos"();

-- Data migration:
--
-- (a) Mark the actionable note in each task thread with key='todo' so the
--     trigger above can find it. Within each task thread the actionable note
--     is the last one by source_created_at. note.key is unique per thread
--     so this is safe.
UPDATE public.note SET key = 'todo'
WHERE id IN (
    SELECT DISTINCT ON (n.thread_id) n.id
    FROM public.note n
    JOIN public.thread t ON t.id = n.thread_id
    WHERE t.key IN ('priorities', 'connections', 'twists', 'notifications')
      AND n.archived_at IS NULL
    ORDER BY n.thread_id, n.source_created_at DESC
);

-- (b) Backfill Tag.Todo for existing users who already joined the Everyone
--     topic but never had the trigger fire. Skip users who already actively
--     marked the note as Done — their decision stands. ON CONFLICT preserves
--     archived rows for users who archived their Todo without marking Done.
INSERT INTO public.note_tag (actor_id, note_id, tag_id)
SELECT uc.contact_id, n.id, 1
FROM public.thread_priority tp
JOIN public.thread t ON t.id = tp.thread_id
JOIN public.note n
  ON n.thread_id = t.id
 AND n.key = 'todo'
 AND n.archived_at IS NULL
JOIN public.user_contact uc
  ON uc.user_id = tp.user_id
 AND uc."primary" = TRUE
 AND uc.linked = TRUE
 AND uc.archived_at IS NULL
WHERE t.key IN ('priorities', 'connections', 'twists', 'notifications')
  AND NOT EXISTS (
      SELECT 1 FROM public.note_tag done
      WHERE done.note_id = n.id
        AND done.actor_id = uc.contact_id
        AND done.tag_id = 3        -- Tag.Done
        AND done.archived_at IS NULL
  )
ON CONFLICT (actor_id, note_id, tag_id) DO NOTHING;

-- (c) Refresh schedule.outstanding_tasks for every (user, onboarding-thread)
--     pair so the agenda reflects the new todos immediately.
SELECT public.recompute_outstanding_tasks(tp.thread_id, tp.user_id)
FROM public.thread_priority tp
JOIN public.thread t ON t.id = tp.thread_id
WHERE t.key IN ('priorities', 'connections', 'twists', 'notifications');
