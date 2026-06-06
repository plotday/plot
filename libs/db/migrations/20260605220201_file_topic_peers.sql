-- Create "file_thread_priority_for_topic_members" function
CREATE FUNCTION "public"."file_thread_priority_for_topic_members" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_author_user_id uuid;
BEGIN
    IF NEW.topic_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        v_author_user_id := NULL;
    END IF;

    INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
    SELECT NEW.id, peer_user_id, NULL::uuid, now()
    FROM (
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM topic_contact tc
        JOIN user_contact uc ON uc.contact_id = tc.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tc.topic_id = NEW.topic_id
        UNION
        SELECT DISTINCT uc.user_id
        FROM topic_group tg
        JOIN group_member gm ON gm.group_id = tg.group_id
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tg.topic_id = NEW.topic_id
    ) peers
    WHERE peer_user_id IS DISTINCT FROM v_author_user_id
      AND NOT EXISTS (
          SELECT 1 FROM topic_member_optout o
          WHERE o.topic_id = NEW.topic_id AND o.user_id = peers.peer_user_id
      )
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

    INSERT INTO thread_state (user_id, thread_id)
    SELECT peer_user_id, NEW.id
    FROM (
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM topic_contact tc
        JOIN user_contact uc ON uc.contact_id = tc.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tc.topic_id = NEW.topic_id
        UNION
        SELECT DISTINCT uc.user_id
        FROM topic_group tg
        JOIN group_member gm ON gm.group_id = tg.group_id
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tg.topic_id = NEW.topic_id
    ) peers
    WHERE peer_user_id IS DISTINCT FROM v_author_user_id
      AND NOT EXISTS (
          SELECT 1 FROM topic_member_optout o
          WHERE o.topic_id = NEW.topic_id AND o.user_id = peers.peer_user_id
      )
    ON CONFLICT (user_id, thread_id) DO NOTHING;

    RETURN NEW;
END;
$$;
-- Create trigger "file_thread_priority_for_topic_members"
CREATE TRIGGER "file_thread_priority_for_topic_members" AFTER INSERT OR UPDATE OF "topic_id" ON "public"."thread" FOR EACH ROW EXECUTE FUNCTION "public"."file_thread_priority_for_topic_members"();
