-- Modify "file_thread_priority_for_group_members" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_for_group_members" () RETURNS trigger LANGUAGE plpgsql AS $$
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
