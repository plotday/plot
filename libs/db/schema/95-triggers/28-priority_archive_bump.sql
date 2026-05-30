-- Archiving (or un-archiving) a focus changes the *effective* priority of its
-- threads — "user".effective_priority_id releases them to the Inbox/root while
-- archived and restores them when un-archived (their stored
-- thread_priority.priority_id never changes). That projection lives in the
-- user.* views, so the threads' own rows must re-emit through the seq cursor
-- for clients to see the move. Bump thread.updated_at (which fires
-- update_seq_and_updated_at) for every thread filed under a focus whose
-- archived_at just transitioned.
--
-- Statement-level with OLD/NEW transition tables so a bulk archive bumps each
-- thread once, and so we only fire on a real archived_at transition — not on
-- every upsert_priority (which always writes archived_at in its SET list).
CREATE OR REPLACE FUNCTION public.bump_threads_on_priority_archive ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE public.thread t
    SET updated_at = now()
    FROM public.thread_priority tp
    JOIN (
        SELECT n.id
        FROM new_table n
        JOIN old_table o ON o.id = n.id
        WHERE (o.archived_at IS NULL) <> (n.archived_at IS NULL)
    ) changed ON changed.id = tp.priority_id
    WHERE t.id = tp.thread_id;
    RETURN NULL;
END;
$$;

-- NB: no column list (AFTER UPDATE, not AFTER UPDATE OF archived_at) — Postgres
-- forbids a column list together with transition tables. The join below filters
-- to rows whose archived_at actually transitioned, so non-archive updates are a
-- cheap no-op.
CREATE TRIGGER bump_threads_on_priority_archive
    AFTER UPDATE ON public.priority
    REFERENCING OLD TABLE AS old_table NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_threads_on_priority_archive ();
