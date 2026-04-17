-- When thread.groups changes, create thread_priority + thread_unread rows
-- for all members of the referenced groups.
CREATE OR REPLACE FUNCTION public.file_thread_priority_for_group_members ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    r RECORD;
    v_peer_priority_id uuid;
    v_author_user_id uuid;
BEGIN
    IF NEW.groups IS NULL OR cardinality(NEW.groups) = 0 THEN
        RETURN NEW;
    END IF;

    -- Only exclude the author from group filing when the thread was authored
    -- by a real user (upsert_thread already filed them). For twist-instance-
    -- authored threads the instance owner is a consumer too (system onboarding
    -- threads are the canonical example), so leave v_author_user_id NULL and
    -- IS DISTINCT FROM NULL lets everyone through.
    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        v_author_user_id := NULL;
    END IF;

    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.groups) AS arr(group_id)
        JOIN public.group_member gm ON gm.group_id = arr.group_id
        JOIN public.user_contact uc
          ON uc.contact_id = gm.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    LOOP
        v_peer_priority_id := public.classify_thread_for_user(r.peer_user_id, NEW.id);
        IF v_peer_priority_id IS NOT NULL THEN
            INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (NEW.id, r.peer_user_id, v_peer_priority_id)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

            INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
            VALUES (r.peer_user_id, NEW.id, 'inform-updates', 50)
            ON CONFLICT (user_id, thread_id) DO NOTHING;
        END IF;
    END LOOP;

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
    v_peer_priority_id uuid;
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

        FOR r_thread IN
            SELECT t.id AS thread_id
            FROM public.thread t
            WHERE NEW.group_id = ANY(t.groups)
              AND t.archived_at IS NULL
        LOOP
            v_peer_priority_id := public.classify_thread_for_user(v_peer_user_id, r_thread.thread_id);
            IF v_peer_priority_id IS NULL THEN
                CONTINUE;
            END IF;

            INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (r_thread.thread_id, v_peer_user_id, v_peer_priority_id)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

            INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
            VALUES (v_peer_user_id, r_thread.thread_id, 'inform-updates', 50)
            ON CONFLICT (user_id, thread_id) DO NOTHING;
        END LOOP;

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
