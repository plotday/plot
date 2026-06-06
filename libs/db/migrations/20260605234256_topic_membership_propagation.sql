-- Create "grant_topic_threads_to_user" function
CREATE FUNCTION "public"."grant_topic_threads_to_user" ("p_topic_id" uuid, "p_user_id" uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    -- Respect opt-out: a user who left does not get re-added by a membership change.
    IF EXISTS (SELECT 1 FROM topic_member_optout o WHERE o.topic_id = p_topic_id AND o.user_id = p_user_id) THEN
        RETURN;
    END IF;

    WITH candidates AS (
        SELECT t.id AS thread_id, public.classify_thread_for_user(p_user_id, t.id) AS pid
        FROM public.thread t
        WHERE t.topic_id = p_topic_id AND t.archived_at IS NULL
    )
    INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
    SELECT c.thread_id, p_user_id, c.pid,
           CASE WHEN c.pid IS NOT NULL THEN NULL ELSE now() END
    FROM candidates c
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO UPDATE
    SET revoked_at = NULL
    WHERE thread_priority.revoked_at IS NOT NULL;

    INSERT INTO thread_state (user_id, thread_id)
    SELECT p_user_id, t.id
    FROM public.thread t
    WHERE t.topic_id = p_topic_id AND t.archived_at IS NULL
    ON CONFLICT (user_id, thread_id) DO NOTHING;
END;
$$;
-- Create "user_has_thread_access" function
CREATE FUNCTION "user"."user_has_thread_access" ("p_user_id" uuid, "p_thread_id" uuid) RETURNS boolean LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_contacts uuid[];
    v_groups uuid[];
    v_topic_id uuid;
BEGIN
    SELECT contacts, groups, topic_id INTO v_contacts, v_groups, v_topic_id
    FROM thread WHERE id = p_thread_id;
    IF NOT FOUND THEN RETURN FALSE; END IF;

    -- direct contact path
    IF EXISTS (
        SELECT 1 FROM user_contact uc
        WHERE uc.user_id = p_user_id AND uc.linked = TRUE AND uc.archived_at IS NULL
          AND uc.contact_id = ANY(v_contacts)
    ) THEN RETURN TRUE; END IF;

    -- group-on-thread path
    IF EXISTS (
        SELECT 1 FROM group_member gm
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE uc.user_id = p_user_id AND gm.group_id = ANY(v_groups)
    ) THEN RETURN TRUE; END IF;

    -- topic path: effective membership (direct contact / via group / admin) minus opt-out
    IF v_topic_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM topic_member_optout o
                       WHERE o.topic_id = v_topic_id AND o.user_id = p_user_id)
       AND (
           EXISTS (
               SELECT 1 FROM topic_contact tc
               JOIN user_contact uc ON uc.contact_id = tc.contact_id
                   AND uc.linked = TRUE AND uc.archived_at IS NULL
               WHERE tc.topic_id = v_topic_id AND uc.user_id = p_user_id
           )
           OR EXISTS (
               SELECT 1 FROM topic_group tg
               JOIN group_member gm ON gm.group_id = tg.group_id
               JOIN user_contact uc ON uc.contact_id = gm.contact_id
                   AND uc.linked = TRUE AND uc.archived_at IS NULL
               WHERE tg.topic_id = v_topic_id AND uc.user_id = p_user_id
           )
           OR EXISTS (
               SELECT 1 FROM topic_admin ta
               WHERE ta.topic_id = v_topic_id AND ta.user_id = p_user_id
           )
       )
    THEN RETURN TRUE; END IF;

    RETURN FALSE;
END;
$$;
-- Create "revoke_topic_threads_from_user" function
CREATE FUNCTION "public"."revoke_topic_threads_from_user" ("p_topic_id" uuid, "p_user_id" uuid) RETURNS void LANGUAGE plpgsql AS $$
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
-- Create "file_thread_priority_on_topic_contact_change" function
CREATE FUNCTION "public"."file_thread_priority_on_topic_contact_change" () RETURNS trigger LANGUAGE plpgsql AS $$
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
-- Create trigger "file_thread_priority_on_topic_contact_change"
CREATE TRIGGER "file_thread_priority_on_topic_contact_change" AFTER DELETE OR INSERT ON "public"."topic_contact" FOR EACH ROW EXECUTE FUNCTION "public"."file_thread_priority_on_topic_contact_change"();
-- Create "file_thread_priority_on_topic_group_change" function
CREATE FUNCTION "public"."file_thread_priority_on_topic_group_change" () RETURNS trigger LANGUAGE plpgsql AS $$
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
-- Create trigger "file_thread_priority_on_topic_group_change"
CREATE TRIGGER "file_thread_priority_on_topic_group_change" AFTER DELETE OR INSERT ON "public"."topic_group" FOR EACH ROW EXECUTE FUNCTION "public"."file_thread_priority_on_topic_group_change"();
-- Modify "file_thread_priority_on_group_member_change" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_on_group_member_change" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    r_thread RECORD;
    v_peer_user_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = NEW.contact_id AND uc.linked = TRUE AND uc.archived_at IS NULL
        LIMIT 1;
        IF v_peer_user_id IS NULL THEN RETURN NEW; END IF;

        WITH affected AS (
            SELECT t.id AS thread_id FROM public.thread t
            WHERE NEW.group_id = ANY(t.groups) AND t.archived_at IS NULL
            UNION
            SELECT t.id FROM public.thread t
            JOIN public.topic_group tg ON tg.group_id = NEW.group_id AND tg.topic_id = t.topic_id
            WHERE t.archived_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.topic_member_optout o
                              WHERE o.topic_id = t.topic_id AND o.user_id = v_peer_user_id)
        ),
        candidates AS (
            SELECT a.thread_id, public.classify_thread_for_user(v_peer_user_id, a.thread_id) AS pid
            FROM affected a
        )
        INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
        SELECT c.thread_id, v_peer_user_id, c.pid,
               CASE WHEN c.pid IS NOT NULL THEN NULL ELSE now() END
        FROM candidates c
        -- Re-join case: if a row already exists with revoked_at set
        -- (the user previously lost access), un-revoke it. Prior priority
        -- filing is preserved — we do not overwrite priority_id /
        -- classify_at. Rows without revoked_at are left alone (the user
        -- already had active access via another path).
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO UPDATE
        SET revoked_at = NULL
        WHERE thread_priority.revoked_at IS NOT NULL;

        INSERT INTO thread_state (user_id, thread_id)
        SELECT v_peer_user_id, a.thread_id
        FROM (
            SELECT t.id AS thread_id FROM public.thread t
            WHERE NEW.group_id = ANY(t.groups) AND t.archived_at IS NULL
            UNION
            SELECT t.id FROM public.thread t
            JOIN public.topic_group tg ON tg.group_id = NEW.group_id AND tg.topic_id = t.topic_id
            WHERE t.archived_at IS NULL
              AND NOT EXISTS (SELECT 1 FROM public.topic_member_optout o
                              WHERE o.topic_id = t.topic_id AND o.user_id = v_peer_user_id)
        ) a
        ON CONFLICT (user_id, thread_id) DO NOTHING;

        RETURN NEW;

    -- DELETE: member removed from group. For every thread whose access
    -- came solely through this group (direct or via topic), mark the
    -- user's thread_priority row as revoked so "user".thread_redacted
    -- emits a cleanup stub (sensitive fields NULLed, archived_at =
    -- revoked_at, seq frozen) and the client hard-deletes its local copy.
    -- See libs/db/AGENTS.md "Handling Access Loss to Synced Entities".
    --
    -- Do NOT bare-DELETE thread_priority here — that would strand the
    -- client (no seq bump, no row in user.thread*, local row lives
    -- forever).
    ELSIF TG_OP = 'DELETE' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = OLD.contact_id AND uc.linked = TRUE AND uc.archived_at IS NULL
        LIMIT 1;
        IF v_peer_user_id IS NULL THEN RETURN OLD; END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id FROM public.thread t
            WHERE OLD.group_id = ANY(t.groups) AND t.archived_at IS NULL
            UNION
            SELECT t.id FROM public.thread t
            JOIN public.topic_group tg ON tg.group_id = OLD.group_id AND tg.topic_id = t.topic_id
            WHERE t.archived_at IS NULL
        LOOP
            IF NOT "user".user_has_thread_access(v_peer_user_id, r_thread.thread_id) THEN
                UPDATE thread_priority SET revoked_at = now()
                WHERE thread_id = r_thread.thread_id AND user_id = v_peer_user_id AND revoked_at IS NULL;

                -- thread_state is consumed via "user".thread's LEFT JOIN;
                -- the redacted stub emits unread=false regardless, so the
                -- row is now meaningless. Bare DELETE is safe because the
                -- table is not directly synced — it feeds computed columns
                -- on user.thread, which is now serving the redacted stub.
                DELETE FROM thread_state
                WHERE thread_id = r_thread.thread_id AND user_id = v_peer_user_id;
            END IF;
        END LOOP;

        RETURN OLD;
    END IF;
END;
$$;
