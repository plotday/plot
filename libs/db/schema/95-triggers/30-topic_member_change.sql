-- topic_contact / topic_group membership changes grant or revoke access to
-- every thread in the topic, mirroring file_thread_priority_on_group_member_change.
-- INSERT classifies inline so the back-catalog appears immediately; DELETE
-- revokes only when user.user_has_thread_access finds no remaining path.

-- Helper: grant a single user access to all of a topic's threads.
CREATE OR REPLACE FUNCTION public.grant_topic_threads_to_user (p_topic_id uuid, p_user_id uuid)
    RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    -- Respect opt-out: a user who left does not get re-added by a membership change.
    IF EXISTS (SELECT 1 FROM topic_member_optout o WHERE o.topic_id = p_topic_id AND o.user_id = p_user_id) THEN
        RETURN;
    END IF;

    WITH candidates AS (
        SELECT t.id AS thread_id, public.classify_thread_for_user(p_user_id, t.id) AS pid
        FROM public.thread t
        WHERE t.topic_id = p_topic_id AND t.archived_at IS NULL
    ),
    filed AS (
        INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
        SELECT c.thread_id, p_user_id, c.pid,
               CASE WHEN c.pid IS NOT NULL THEN NULL ELSE now() END
        FROM candidates c
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO UPDATE
        SET revoked_at = NULL
        WHERE thread_priority.revoked_at IS NOT NULL
        RETURNING thread_priority.thread_id, thread_priority.priority_id,
                  (xmax = 0) AS inserted
    )
    INSERT INTO classification_decision (thread_id, user_id, priority_id, stage, classifier)
    SELECT f.thread_id, p_user_id, f.priority_id, 'sql:applied', 'sql:classify_thread_for_user'
    FROM filed f
    WHERE f.inserted AND f.priority_id IS NOT NULL;

    INSERT INTO thread_state (user_id, thread_id)
    SELECT p_user_id, t.id
    FROM public.thread t
    WHERE t.topic_id = p_topic_id AND t.archived_at IS NULL
    ON CONFLICT (user_id, thread_id) DO NOTHING;
END;
$$;

-- Helper: revoke a single user from a topic's threads when no other path remains.
CREATE OR REPLACE FUNCTION public.revoke_topic_threads_from_user (p_topic_id uuid, p_user_id uuid)
    RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    r_thread RECORD;
BEGIN
    FOR r_thread IN
        SELECT t.id AS thread_id FROM public.thread t
        WHERE t.topic_id = p_topic_id AND t.archived_at IS NULL
    LOOP
        IF NOT "user".user_has_thread_access(p_user_id, r_thread.thread_id) THEN
            UPDATE thread_priority SET revoked_at = now()
            WHERE thread_id = r_thread.thread_id AND user_id = p_user_id AND revoked_at IS NULL;
            DELETE FROM thread_state
            WHERE thread_id = r_thread.thread_id AND user_id = p_user_id;
        END IF;
    END LOOP;
END;
$$;

-- topic_contact: one contact → one user.
CREATE OR REPLACE FUNCTION public.file_thread_priority_on_topic_contact_change ()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_user_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT uc.user_id INTO v_user_id FROM user_contact uc
        WHERE uc.contact_id = NEW.contact_id AND uc.linked = TRUE AND uc.archived_at IS NULL LIMIT 1;
        IF v_user_id IS NOT NULL THEN PERFORM public.grant_topic_threads_to_user(NEW.topic_id, v_user_id); END IF;
        RETURN NEW;
    ELSE
        SELECT uc.user_id INTO v_user_id FROM user_contact uc
        WHERE uc.contact_id = OLD.contact_id AND uc.linked = TRUE AND uc.archived_at IS NULL LIMIT 1;
        IF v_user_id IS NOT NULL THEN PERFORM public.revoke_topic_threads_from_user(OLD.topic_id, v_user_id); END IF;
        RETURN OLD;
    END IF;
END;
$$;

CREATE TRIGGER file_thread_priority_on_topic_contact_change
    AFTER INSERT OR DELETE ON public.topic_contact
    FOR EACH ROW EXECUTE FUNCTION public.file_thread_priority_on_topic_contact_change ();

-- topic_group: one group → all its members' users.
CREATE OR REPLACE FUNCTION public.file_thread_priority_on_topic_group_change ()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_user_id uuid;
    v_topic_id uuid;
    v_group_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN v_topic_id := NEW.topic_id; v_group_id := NEW.group_id;
    ELSE v_topic_id := OLD.topic_id; v_group_id := OLD.group_id; END IF;

    FOR v_user_id IN
        SELECT DISTINCT uc.user_id FROM group_member gm
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE gm.group_id = v_group_id
    LOOP
        IF TG_OP = 'INSERT' THEN PERFORM public.grant_topic_threads_to_user(v_topic_id, v_user_id);
        ELSE PERFORM public.revoke_topic_threads_from_user(v_topic_id, v_user_id); END IF;
    END LOOP;

    IF TG_OP = 'INSERT' THEN RETURN NEW; ELSE RETURN OLD; END IF;
END;
$$;

CREATE TRIGGER file_thread_priority_on_topic_group_change
    AFTER INSERT OR DELETE ON public.topic_group
    FOR EACH ROW EXECUTE FUNCTION public.file_thread_priority_on_topic_group_change ();
