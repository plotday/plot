-- Modify "user_has_thread_access" function
CREATE OR REPLACE FUNCTION "user"."user_has_thread_access" ("p_user_id" uuid, "p_thread_id" uuid) RETURNS boolean LANGUAGE plpgsql STABLE AS $$
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
       AND EXISTS (SELECT 1 FROM topic tp
                   WHERE tp.id = v_topic_id AND tp.archived_at IS NULL)
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
