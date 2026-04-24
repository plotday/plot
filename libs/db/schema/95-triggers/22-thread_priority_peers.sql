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
-- Each peer's priority is resolved via classify_thread_for_user. Uses
-- ON CONFLICT DO NOTHING so a peer who has already filed the thread is not
-- overwritten.
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

    -- Only auto-file peers for user-authored threads. For twist-authored
    -- threads, filing happens exclusively through each user's own
    -- upsert_thread call (which promotes them from pending_contacts).
    IF NOT EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        RETURN NEW;
    END IF;
    v_author_user_id := NEW.created_by;

    -- Compute old contacts for delta (empty on INSERT).
    IF TG_OP = 'UPDATE' THEN
        v_old_contacts := COALESCE(OLD.contacts, ARRAY[]::uuid[]);
    ELSE
        v_old_contacts := ARRAY[]::uuid[];
    END IF;

    -- thread_priority for ALL contacts (idempotent via ON CONFLICT DO NOTHING).
    -- Each peer classifies against their own channels — channel_default_marker
    -- only stamps when the peer themselves owns the channel with this topic
    -- and its default matches the chosen priority.
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
            INSERT INTO thread_priority (thread_id, user_id, priority_id, applied_default_channel_id)
            VALUES (
                NEW.id,
                r.peer_user_id,
                v_peer_priority_id,
                public.channel_default_marker (
                    r.peer_user_id, NEW.id, v_peer_priority_id
                )
            )
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;
        END IF;
    END LOOP;

    -- thread_unread for NEWLY ADDED contacts only, so shared threads appear
    -- as unread for peers. ON CONFLICT DO NOTHING preserves read state.
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
