-- Modify "file_thread_priority_on_group_member_change" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_on_group_member_change" () RETURNS trigger LANGUAGE plpgsql AS $$
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

        WITH candidates AS (
            SELECT t.id AS thread_id,
                   public.classify_thread_for_user(v_peer_user_id, t.id) AS pid
            FROM public.thread t
            WHERE NEW.group_id = ANY(t.groups)
              AND t.archived_at IS NULL
        )
        INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
        SELECT c.thread_id,
               v_peer_user_id,
               c.pid,
               CASE WHEN c.pid IS NOT NULL THEN NULL ELSE now() END
        FROM candidates c
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

        INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
        SELECT v_peer_user_id, t.id, 'inform-updates', 50
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

-- Backfill: resolve every currently-pending thread_priority row that the
-- SQL classifier can place. These are mostly rows stranded by the previous
-- group_member trigger (new signups whose onboarding threads sat pending
-- until the hourly sweep). classify_thread_for_user is STABLE and reads
-- the same priority/topic/key data the worker would have used, so this
-- catches the common cases (priority_prefix, topic_shortcircuit, keyed
-- priority match, root fallback) without invoking the LLM. Rows that the
-- SQL classifier can't resolve (returns NULL — e.g. team threads with no
-- matching team priority) stay pending so the worker can attempt them.
WITH classified AS (
    SELECT tp.thread_id,
           tp.user_id,
           public.classify_thread_for_user(tp.user_id, tp.thread_id) AS pid
    FROM public.thread_priority tp
    WHERE tp.priority_id IS NULL
      AND tp.classify_at IS NOT NULL
)
UPDATE public.thread_priority tp
SET priority_id = c.pid,
    classify_at = NULL
FROM classified c
WHERE tp.thread_id = c.thread_id
  AND tp.user_id = c.user_id
  AND c.pid IS NOT NULL;
