-- Populate thread_priority rows for every linked user appearing in
-- thread.contacts (beyond the author). Fires after INSERT or after
-- contacts changes on an existing thread, so both upsert_thread RPC
-- callers and raw insertInto("thread") writers (twist runtime, dev
-- activities) share the same peer-filing behaviour.
--
-- Each peer's priority is resolved via classify_thread_for_user, which
-- evaluates user-defined priority rules or falls back to the user's
-- personal root. Uses ON CONFLICT DO NOTHING so a peer who has already
-- filed the thread (via a manual move) is not overwritten.
CREATE OR REPLACE FUNCTION public.file_thread_priority_peers ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    r RECORD;
    v_peer_priority_id uuid;
    v_author_user_id uuid;
    v_old_contacts uuid[];
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
    END IF;

    -- Compute old contacts for delta (empty on INSERT)
    IF TG_OP = 'UPDATE' THEN
        v_old_contacts := COALESCE(OLD.contacts, ARRAY[]::uuid[]);
    ELSE
        v_old_contacts := ARRAY[]::uuid[];
    END IF;

    -- Exclude the author (user_id or twist_instance owner) from peer filing
    -- so we don't double-insert against the author trigger.
    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        SELECT pt.owner_id INTO v_author_user_id
        FROM public.twist_instance pt
        WHERE pt.id = NEW.created_by;
    END IF;

    -- thread_priority for ALL contacts (idempotent via ON CONFLICT DO NOTHING)
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    LOOP
        v_peer_priority_id := public.classify_thread_for_user(r.peer_user_id, NEW.id);
        IF v_peer_priority_id IS NOT NULL THEN
            INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (NEW.id, r.peer_user_id, v_peer_priority_id)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;
        END IF;
    END LOOP;

    -- thread_unread for NEWLY ADDED contacts only, so shared threads
    -- appear as unread for peers. Uses ON CONFLICT DO NOTHING to avoid
    -- overwriting existing read state.
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
          AND arr.contact_id != ALL(v_old_contacts)
    LOOP
        INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
        VALUES (r.peer_user_id, NEW.id, 'inform-updates', 50)
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END LOOP;

    RETURN NEW;
END;
$$;

CREATE TRIGGER file_thread_priority_peers
    AFTER INSERT OR UPDATE OF contacts
    ON public.thread
    FOR EACH ROW
    EXECUTE FUNCTION public.file_thread_priority_peers ();
