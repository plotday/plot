-- Create a new topic. Creator automatically becomes admin.
CREATE OR REPLACE FUNCTION public.create_topic (
    p_user_id uuid,
    p_name text,
    p_type topic_type DEFAULT 'private',
    p_join_policy topic_join_policy DEFAULT 'member',
    p_team_id bigint DEFAULT NULL,
    p_member_contact_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
    RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_topic_id uuid;
BEGIN
    IF p_team_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM team_user
            WHERE team_id = p_team_id AND user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'User is not a member of this team';
        END IF;
    END IF;

    INSERT INTO topic (name, type, join_policy, team_id, created_by)
    VALUES (p_name, p_type, p_join_policy, p_team_id, p_user_id)
    RETURNING id INTO v_topic_id;

    INSERT INTO topic_admin (topic_id, user_id)
    VALUES (v_topic_id, p_user_id);

    IF cardinality(p_member_contact_ids) > 0 THEN
        INSERT INTO topic_member (topic_id, contact_id)
        SELECT v_topic_id, unnest(p_member_contact_ids)
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_topic_id;
END;
$function$;

-- Add contacts to a topic's member list.
CREATE OR REPLACE FUNCTION public.add_topic_members (
    p_user_id uuid,
    p_topic_id uuid,
    p_contact_ids uuid[]
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_topic RECORD;
BEGIN
    SELECT * INTO v_topic FROM topic WHERE id = p_topic_id;
    IF v_topic IS NULL THEN
        RAISE EXCEPTION 'Topic not found';
    END IF;
    IF v_topic.auto_maintained THEN
        RAISE EXCEPTION 'Cannot modify members of auto-maintained topic';
    END IF;

    IF v_topic.join_policy = 'admin' THEN
        IF NOT EXISTS (
            SELECT 1 FROM topic_admin
            WHERE topic_id = p_topic_id AND user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'Only admins can add members to this topic';
        END IF;
    ELSIF v_topic.join_policy = 'member' THEN
        IF NOT EXISTS (
            SELECT 1 FROM topic_admin
            WHERE topic_id = p_topic_id AND user_id = p_user_id
        ) AND NOT EXISTS (
            SELECT 1 FROM topic_member tm
            JOIN user_contact uc ON uc.contact_id = tm.contact_id
                AND uc.linked = TRUE AND uc.archived_at IS NULL
            WHERE tm.topic_id = p_topic_id AND uc.user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'Only members can add members to this topic';
        END IF;
    END IF;

    INSERT INTO topic_member (topic_id, contact_id)
    SELECT p_topic_id, unnest(p_contact_ids)
    ON CONFLICT DO NOTHING;
END;
$function$;

-- Remove contacts from a topic's member list.
CREATE OR REPLACE FUNCTION public.remove_topic_members (
    p_user_id uuid,
    p_topic_id uuid,
    p_contact_ids uuid[]
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_topic RECORD;
BEGIN
    SELECT * INTO v_topic FROM topic WHERE id = p_topic_id;
    IF v_topic IS NULL THEN
        RAISE EXCEPTION 'Topic not found';
    END IF;
    IF v_topic.auto_maintained THEN
        RAISE EXCEPTION 'Cannot modify members of auto-maintained topic';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM topic_admin
        WHERE topic_id = p_topic_id AND user_id = p_user_id
    ) AND NOT EXISTS (
        SELECT 1 FROM topic_member tm
        JOIN user_contact uc ON uc.contact_id = tm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE tm.topic_id = p_topic_id AND uc.user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'Insufficient permission to remove topic members';
    END IF;

    DELETE FROM topic_member
    WHERE topic_id = p_topic_id AND contact_id = ANY(p_contact_ids);
END;
$function$;
