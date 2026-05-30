-- Populate thread_priority rows for peer users appearing in thread.contacts —
-- but only for user-authored threads, where the author's sync necessarily
-- attests their peers (think: share_thread, or a user manually creating a
-- thread with a contact list).
--
-- Twist-authored threads do NOT auto-file peers here. Their peers gain
-- visibility only via their own connector's upsert_thread call (which
-- independently confirms membership via the external source). This prevents
-- the admission hole where one user's rogue connector could silently admit
-- peers by merely listing their contacts.
--
-- Pending-classification design: peers get pending rows
-- (priority_id NULL, classify_at = now()). The API enqueues a
-- ClassifyJob for each new row; the consumer Worker (workers/classify)
-- runs the LLM-aware classifier and fills priority_id. Until then peer
-- users see nothing for the thread; after classify_visibility_window()
-- elapses the user.* views surface the thread at root as a fallback.
-- See docs/superpowers/specs/2026-05-18-hybrid-classifier-production-wiring-design.md.
CREATE OR REPLACE FUNCTION public.file_thread_priority_peers ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_author_user_id uuid;
    v_old_contacts uuid[];
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
    END IF;

    -- Only auto-file peers for user-authored threads.
    IF NOT EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        RETURN NEW;
    END IF;
    v_author_user_id := NEW.created_by;

    IF TG_OP = 'UPDATE' THEN
        v_old_contacts := COALESCE(OLD.contacts, ARRAY[]::uuid[]);
    ELSE
        v_old_contacts := ARRAY[]::uuid[];
    END IF;

    -- Mark every peer pending classification. applied_default_channel_id
    -- is set by the consumer Worker once it knows the chosen priority.
    INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
    SELECT NEW.id, peer.user_id, NULL::uuid, now()
    FROM (
        SELECT DISTINCT uc.user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    ) peer
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

    -- thread_state for newly-added contacts only. Harmless while the
    -- parent thread_priority row is hidden — only surfaces in user.*
    -- views once the visibility filter admits the row. active and importance
    -- use the table defaults (FALSE, 50).
    INSERT INTO thread_state (user_id, thread_id)
    SELECT peer.user_id, NEW.id
    FROM (
        SELECT DISTINCT uc.user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
          AND arr.contact_id != ALL(v_old_contacts)
    ) peer
    ON CONFLICT (user_id, thread_id) DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER file_thread_priority_peers
    AFTER INSERT OR UPDATE OF contacts
    ON public.thread
    FOR EACH ROW
    EXECUTE FUNCTION public.file_thread_priority_peers ();
