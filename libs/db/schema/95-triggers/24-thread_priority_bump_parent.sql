-- Parent-seq bump: when thread_priority.priority_id changes (consumer
-- Worker finalizing a pending row, sweep-driven retry, or a user move),
-- bump the parent thread's seq so seq-cursor-based sync re-emits the
-- thread to clients that already pulled it. See AGENTS.md "Bump Parent
-- seq on Child-Table Changes".
--
-- Excludes pure classify_at clearing (the consumer's "same result"
-- branch) so a no-op classification does not trigger needless client
-- re-sync. classify_at is internal-only and never exposed to clients.
CREATE OR REPLACE FUNCTION public.bump_thread_seq_on_priority_change ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE public.thread
    SET updated_at = now()
    WHERE id = NEW.thread_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER thread_priority_bump_parent
    AFTER UPDATE OF priority_id ON public.thread_priority
    FOR EACH ROW
    WHEN (NEW.priority_id IS DISTINCT FROM OLD.priority_id)
    EXECUTE FUNCTION public.bump_thread_seq_on_priority_change ();
