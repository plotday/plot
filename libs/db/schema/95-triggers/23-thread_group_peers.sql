-- When thread.groups changes, create pending thread_priority +
-- thread_state rows for all members of the referenced groups. The
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

    INSERT INTO thread_state (user_id, thread_id)
    SELECT peer.user_id, NEW.id
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
-- thread_priority/thread_state for all threads that reference the group
-- directly (thread.groups) AND all threads whose topic includes the group
-- (topic_group). The revoke decision is centralised in
-- user.user_has_thread_access so every access path (direct contact, group
-- on thread, topic membership) is checked identically.
--
-- On INSERT we classify the threads inline via classify_thread_for_user
-- instead of leaving the rows pending for the async worker. The async
-- pending-row design is right for new threads (the API enqueues a
-- ClassifyJob right after upsert_thread commits) but wrong here: nothing
-- enqueues jobs when a user is *added to a group* containing existing
-- threads, so without inline classification the rows stay pending until
-- the hourly sweep, hiding the threads for ~5 minutes (the visibility
-- window) and then surfacing them at the user's root priority instead
-- of the priority that their topic dictates. For new signups joining the
-- "Everyone" group this means onboarding threads (topic
-- 'priority:@plot.app:*') never appear under Using Plot until the sweep
-- runs. classify_thread_for_user resolves them via the priority_prefix
-- stage immediately. Rows that the SQL classifier can't resolve (team
-- threads with no matching team priority) stay pending so the LLM-aware
-- worker can still attempt them on the next sweep.
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

CREATE TRIGGER file_thread_priority_on_group_member_change
    AFTER INSERT OR DELETE ON public.group_member
    FOR EACH ROW
    EXECUTE FUNCTION public.file_thread_priority_on_group_member_change ();
