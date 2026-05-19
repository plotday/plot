-- When thread.groups changes, create pending thread_priority +
-- thread_unread rows for all members of the referenced groups. The
-- consumer Worker resolves each peer's priority via the LLM-aware
-- classifier; see 22-thread_priority_peers.sql for the pending-row
-- pattern and 24-thread_priority_bump_parent.sql for the parent-seq
-- bump on resolution.
CREATE OR REPLACE FUNCTION public.file_thread_priority_for_group_members ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_author_user_id uuid;
BEGIN
    IF NEW.groups IS NULL OR cardinality(NEW.groups) = 0 THEN
        RETURN NEW;
    END IF;

    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        v_author_user_id := NULL;
    END IF;

    INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
    SELECT NEW.id, peer.user_id, NULL::uuid, now()
    FROM (
        SELECT DISTINCT uc.user_id
        FROM unnest(NEW.groups) AS arr(group_id)
        JOIN public.group_member gm ON gm.group_id = arr.group_id
        JOIN public.user_contact uc
          ON uc.contact_id = gm.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    ) peer
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

    INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
    SELECT peer.user_id, NEW.id, 'inform-updates', 50
    FROM (
        SELECT DISTINCT uc.user_id
        FROM unnest(NEW.groups) AS arr(group_id)
        JOIN public.group_member gm ON gm.group_id = arr.group_id
        JOIN public.user_contact uc
          ON uc.contact_id = gm.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    ) peer
    ON CONFLICT (user_id, thread_id) DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER file_thread_priority_for_group_members
    AFTER INSERT OR UPDATE OF groups
    ON public.thread
    FOR EACH ROW
    EXECUTE FUNCTION public.file_thread_priority_for_group_members ();

-- When a contact is added to or removed from a group, cascade to
-- thread_priority/thread_unread for all threads that reference the group.
CREATE OR REPLACE FUNCTION public.file_thread_priority_on_group_member_change ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    r_thread RECORD;
    v_peer_user_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = NEW.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        LIMIT 1;

        IF v_peer_user_id IS NULL THEN
            RETURN NEW;
        END IF;

        -- Mark every thread referencing the group pending for this peer.
        INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
        SELECT t.id, v_peer_user_id, NULL::uuid, now()
        FROM public.thread t
        WHERE NEW.group_id = ANY(t.groups)
          AND t.archived_at IS NULL
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

        INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
        SELECT t.id, v_peer_user_id, 'inform-updates', 50
        FROM public.thread t
        WHERE NEW.group_id = ANY(t.groups)
          AND t.archived_at IS NULL
        ON CONFLICT (user_id, thread_id) DO NOTHING;

        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = OLD.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        LIMIT 1;

        IF v_peer_user_id IS NULL THEN
            RETURN OLD;
        END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id
            FROM public.thread t
            WHERE OLD.group_id = ANY(t.groups)
              AND t.archived_at IS NULL
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM public.thread t2
                WHERE t2.id = r_thread.thread_id
                  AND (
                    t2.contacts && "user".user_contact_ids(v_peer_user_id)
                    OR EXISTS (
                        SELECT 1 FROM unnest(t2.groups) AS gid
                        JOIN group_member gm2 ON gm2.group_id = gid
                        JOIN user_contact uc2 ON uc2.contact_id = gm2.contact_id
                            AND uc2.linked = TRUE AND uc2.archived_at IS NULL
                        WHERE uc2.user_id = v_peer_user_id
                          AND gm2.group_id != OLD.group_id
                    )
                  )
            ) THEN
                DELETE FROM thread_priority
                WHERE thread_id = r_thread.thread_id
                  AND user_id = v_peer_user_id;

                DELETE FROM thread_unread
                WHERE thread_id = r_thread.thread_id
                  AND user_id = v_peer_user_id;
            END IF;
        END LOOP;

        RETURN OLD;
    END IF;
END;
$$;

CREATE TRIGGER file_thread_priority_on_group_member_change
    AFTER INSERT OR DELETE ON public.group_member
    FOR EACH ROW
    EXECUTE FUNCTION public.file_thread_priority_on_group_member_change ();
