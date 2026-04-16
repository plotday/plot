-- Per-user Tag.Todo on the actionable "task" notes inside the four onboarding
-- threads that ask the user to take an action (priorities, connections, twists,
-- notifications). Fires on the same event as file_onboarding_schedules: the
-- thread_priority insert that happens when a user joins the Everyone group and
-- the file_thread_priority_on_group_member_change trigger files them in.
--
-- Without this trigger, no user ever has a todo on these threads, so
-- schedule.outstanding_tasks stays false and the agenda items can't be marked
-- finished. We use note.key = 'todo' to identify the actionable note inside
-- each task thread (set by the migration that ships this trigger).
CREATE OR REPLACE FUNCTION public.file_onboarding_todos ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
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

CREATE TRIGGER file_onboarding_todos
    AFTER INSERT ON public.thread_priority
    FOR EACH ROW
    EXECUTE FUNCTION public.file_onboarding_todos ();
