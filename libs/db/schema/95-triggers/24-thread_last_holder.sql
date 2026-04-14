-- "Last holder" cleanup: when every thread_priority row for a thread is
-- archived AND no active links remain, archive the thread itself. Combined
-- with the archived_at IS NULL predicate in thread_twist_key_unique, this
-- frees the (twist_id, key) slot so a future sync can create a fresh thread
-- (new id, no carried notes) if someone is later added to the external item.
CREATE OR REPLACE FUNCTION public.maybe_archive_thread_last_holder ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_thread_id uuid;
BEGIN
    v_thread_id := CASE TG_OP
        WHEN 'DELETE' THEN OLD.thread_id
        ELSE NEW.thread_id
    END;

    IF v_thread_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- If the thread already has a global archived_at, nothing to do.
    IF EXISTS (
        SELECT 1 FROM public.thread t
        WHERE t.id = v_thread_id AND t.archived_at IS NOT NULL
    ) THEN
        RETURN NULL;
    END IF;

    -- Active thread_priority rows?
    IF EXISTS (
        SELECT 1 FROM public.thread_priority tp
        WHERE tp.thread_id = v_thread_id
          AND tp.archived_at IS NULL
    ) THEN
        RETURN NULL;
    END IF;

    -- Any remaining links pointing at this thread?
    IF EXISTS (
        SELECT 1 FROM public.link l
        WHERE l.thread_id = v_thread_id
    ) THEN
        RETURN NULL;
    END IF;

    UPDATE public.thread t
    SET archived_at = now()
    WHERE t.id = v_thread_id
      AND t.archived_at IS NULL;

    RETURN NULL;
END;
$$;

-- Fires after per-user archive (thread_priority.archived_at set).
CREATE TRIGGER maybe_archive_thread_after_priority_archive
    AFTER UPDATE OF archived_at ON public.thread_priority
    FOR EACH ROW
    WHEN (NEW.archived_at IS NOT NULL AND (OLD.archived_at IS NULL OR OLD.archived_at IS DISTINCT FROM NEW.archived_at))
    EXECUTE FUNCTION public.maybe_archive_thread_last_holder ();

-- Fires after a link row is removed (e.g. connector uninstall deletes links).
CREATE TRIGGER maybe_archive_thread_after_link_delete
    AFTER DELETE ON public.link
    FOR EACH ROW
    EXECUTE FUNCTION public.maybe_archive_thread_last_holder ();
