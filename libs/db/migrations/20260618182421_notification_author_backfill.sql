-- Data backfill: credit connector-synced threads to their human originator
-- instead of the connection's twist_instance.
--
-- When a messaging connector (Gmail, etc.) saved a thread with no explicit link
-- author, the runtime defaulted thread.author_id to the connection's
-- twist_instance, whose actor name renders as "<Connector> (<account>)" — e.g.
-- "Gmail (Plot)". That leaked into notifications (as the author) and the thread
-- header. The runtime now credits the first note's author instead (see
-- selectThreadAuthorSpec in workers/api); this repoints threads created before
-- that fix the same way: where author_id is a twist_instance and the thread has
-- a human (contact) note author, set author_id to the FIRST such note's author
-- (the originator). Genuine twist-authored threads (notes authored by the twist,
-- no human note) are left untouched.
--
-- thread.author_id is guarded as immutable by protect_thread_created_by, which
-- would otherwise revert this UPDATE. Rather than DISABLE TRIGGER (a table-wide
-- lock on the hot `thread` table), temporarily relax the guard to permit ONLY
-- the twist_instance -> contact correction, run the backfill (row locks only),
-- then restore the exact original guard. DDL is transactional, so concurrent
-- sessions never observe the relaxed definition. The seq trigger stays enabled,
-- so every updated thread re-syncs its corrected author to clients.
--
-- Idempotent: only rows whose author_id is still a twist_instance are touched.

-- Step 1 — temporarily allow the twist_instance -> contact author correction.
CREATE OR REPLACE FUNCTION public.protect_thread_created_by ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- author_id is immutable once set, EXCEPT correcting a connection's
    -- twist_instance author to a human contact (the one-time backfill below).
    IF NOT (
        OLD.author_id IS DISTINCT FROM NEW.author_id
        AND EXISTS (SELECT 1 FROM public.twist_instance ti WHERE ti.id = OLD.author_id)
        AND EXISTS (SELECT 1 FROM public.contact c WHERE c.id = NEW.author_id)
    ) THEN
        NEW.author_id := COALESCE(OLD.author_id, NEW.author_id);
    END IF;

    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
        RETURN NEW;
    END IF;
    IF OLD.archived_at IS NULL THEN
        NEW.created_by := OLD.created_by;
    END IF;
    RETURN NEW;
END;
$function$;

-- Step 2 — repoint each affected thread to its first human note author.
WITH first_human_author AS (
    SELECT DISTINCT ON (n.thread_id)
        n.thread_id,
        n.author_id AS contact_id
    FROM public.note n
    JOIN public.contact c ON c.id = n.author_id
    WHERE n.archived_at IS NULL
      AND n.draft = false
    ORDER BY n.thread_id, n.created_at ASC, n.id ASC
)
UPDATE public.thread t
SET author_id = fha.contact_id
FROM first_human_author fha
WHERE fha.thread_id = t.id
  AND t.author_id IS DISTINCT FROM fha.contact_id
  AND EXISTS (SELECT 1 FROM public.twist_instance ti WHERE ti.id = t.author_id);

-- Step 3 — restore the original immutability guard. This MUST match
-- schema/95-triggers/13-thread_created_by_protection.sql exactly, or
-- diff-schema-migrations will report drift.
CREATE OR REPLACE FUNCTION public.protect_thread_created_by ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- author_id is immutable once set: preserve original value if it existed
    NEW.author_id := COALESCE(OLD.author_id, NEW.author_id);

    -- Un-archiving: allow created_by update
    IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
        RETURN NEW;
    END IF;
    -- Not archived: prevent created_by changes
    IF OLD.archived_at IS NULL THEN
        NEW.created_by := OLD.created_by;
    END IF;
    RETURN NEW;
END;
$function$;
