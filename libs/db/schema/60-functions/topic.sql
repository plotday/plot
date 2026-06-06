-- Whether the user may manage a topic's membership: admins always; otherwise
-- only when the topic has an `open` join policy AND the user is an effective,
-- non-opted-out member (direct contact OR via an included group). Inlined
-- table reads (no call to user.user_topic_ids) so this stays a 60-functions
-- public function with no cross-schema forward reference.
CREATE OR REPLACE FUNCTION public.user_can_manage_topic (p_user_id uuid, p_topic_id uuid)
    RETURNS boolean LANGUAGE plpgsql STABLE SET search_path TO 'public' AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM topic_admin WHERE topic_id = p_topic_id AND user_id = p_user_id) THEN
        RETURN TRUE;
    END IF;
    RETURN EXISTS (SELECT 1 FROM topic t WHERE t.id = p_topic_id AND t.join_policy = 'open')
       AND NOT EXISTS (SELECT 1 FROM topic_member_optout o WHERE o.topic_id = p_topic_id AND o.user_id = p_user_id)
       AND (
           EXISTS (SELECT 1 FROM topic_contact tc
                   JOIN user_contact uc ON uc.contact_id = tc.contact_id AND uc.linked = TRUE AND uc.archived_at IS NULL
                   WHERE tc.topic_id = p_topic_id AND uc.user_id = p_user_id)
           OR EXISTS (SELECT 1 FROM topic_group tg
                      JOIN group_member gm ON gm.group_id = tg.group_id
                      JOIN user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = TRUE AND uc.archived_at IS NULL
                      WHERE tg.topic_id = p_topic_id AND uc.user_id = p_user_id)
       );
END;
$$;

-- Create a topic. Creator becomes admin; initial contacts/groups added.
CREATE OR REPLACE FUNCTION public.create_topic (
    p_user_id uuid, p_name text, p_announce boolean DEFAULT FALSE,
    p_team_id bigint DEFAULT NULL,
    p_contact_ids uuid[] DEFAULT ARRAY[]::uuid[],
    p_group_ids uuid[] DEFAULT ARRAY[]::uuid[]
) RETURNS uuid LANGUAGE plpgsql SET search_path TO 'public' AS $$
DECLARE v_topic_id uuid;
BEGIN
    IF p_team_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM team_user WHERE team_id = p_team_id AND user_id = p_user_id) THEN
            RAISE EXCEPTION 'User is not a member of this team';
        END IF;
    END IF;
    INSERT INTO topic (name, announce, team_id, created_by)
    VALUES (p_name, p_announce, p_team_id, p_user_id) RETURNING id INTO v_topic_id;
    INSERT INTO topic_admin (topic_id, user_id) VALUES (v_topic_id, p_user_id);
    IF cardinality(p_contact_ids) > 0 THEN
        INSERT INTO topic_contact (topic_id, contact_id)
        SELECT v_topic_id, unnest(p_contact_ids) ON CONFLICT DO NOTHING;
    END IF;
    IF cardinality(p_group_ids) > 0 THEN
        INSERT INTO topic_group (topic_id, group_id)
        SELECT v_topic_id, unnest(p_group_ids) ON CONFLICT DO NOTHING;
    END IF;
    RETURN v_topic_id;
END;
$$;

-- add/remove topic contacts
CREATE OR REPLACE FUNCTION public.add_topic_contacts (p_user_id uuid, p_topic_id uuid, p_contact_ids uuid[])
    RETURNS void LANGUAGE plpgsql SET search_path TO 'public' AS $$
DECLARE v_topic RECORD;
BEGIN
    SELECT * INTO v_topic FROM topic WHERE id = p_topic_id;
    IF v_topic IS NULL THEN RAISE EXCEPTION 'Topic not found'; END IF;
    IF v_topic.auto_maintained THEN RAISE EXCEPTION 'Cannot modify auto-maintained topic'; END IF;
    IF NOT public.user_can_manage_topic(p_user_id, p_topic_id) THEN
        RAISE EXCEPTION 'Insufficient permission to modify topic membership';
    END IF;
    INSERT INTO topic_contact (topic_id, contact_id)
    SELECT p_topic_id, unnest(p_contact_ids) ON CONFLICT DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_topic_contacts (p_user_id uuid, p_topic_id uuid, p_contact_ids uuid[])
    RETURNS void LANGUAGE plpgsql SET search_path TO 'public' AS $$
DECLARE v_topic RECORD;
BEGIN
    SELECT * INTO v_topic FROM topic WHERE id = p_topic_id;
    IF v_topic IS NULL THEN RAISE EXCEPTION 'Topic not found'; END IF;
    IF v_topic.auto_maintained THEN RAISE EXCEPTION 'Cannot modify auto-maintained topic'; END IF;
    IF NOT public.user_can_manage_topic(p_user_id, p_topic_id) THEN
        RAISE EXCEPTION 'Insufficient permission to modify topic membership';
    END IF;
    DELETE FROM topic_contact WHERE topic_id = p_topic_id AND contact_id = ANY(p_contact_ids);
END;
$$;

-- add/remove topic groups
CREATE OR REPLACE FUNCTION public.add_topic_groups (p_user_id uuid, p_topic_id uuid, p_group_ids uuid[])
    RETURNS void LANGUAGE plpgsql SET search_path TO 'public' AS $$
DECLARE v_topic RECORD;
BEGIN
    SELECT * INTO v_topic FROM topic WHERE id = p_topic_id;
    IF v_topic IS NULL THEN RAISE EXCEPTION 'Topic not found'; END IF;
    IF v_topic.auto_maintained THEN RAISE EXCEPTION 'Cannot modify auto-maintained topic'; END IF;
    IF NOT public.user_can_manage_topic(p_user_id, p_topic_id) THEN
        RAISE EXCEPTION 'Insufficient permission to modify topic membership';
    END IF;
    IF EXISTS (
        SELECT 1 FROM unnest(p_group_ids) AS gid
        WHERE NOT public.user_can_address_group(p_user_id, gid)
    ) THEN
        RAISE EXCEPTION 'Insufficient permission to use one of these groups';
    END IF;
    INSERT INTO topic_group (topic_id, group_id)
    SELECT p_topic_id, unnest(p_group_ids) ON CONFLICT DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_topic_groups (p_user_id uuid, p_topic_id uuid, p_group_ids uuid[])
    RETURNS void LANGUAGE plpgsql SET search_path TO 'public' AS $$
DECLARE v_topic RECORD;
BEGIN
    SELECT * INTO v_topic FROM topic WHERE id = p_topic_id;
    IF v_topic IS NULL THEN RAISE EXCEPTION 'Topic not found'; END IF;
    IF v_topic.auto_maintained THEN RAISE EXCEPTION 'Cannot modify auto-maintained topic'; END IF;
    IF NOT public.user_can_manage_topic(p_user_id, p_topic_id) THEN
        RAISE EXCEPTION 'Insufficient permission to modify topic membership';
    END IF;
    DELETE FROM topic_group WHERE topic_id = p_topic_id AND group_id = ANY(p_group_ids);
END;
$$;

-- join: clear any opt-out (rejoin) and add the user's primary contact as a
-- direct member (idempotent). Allowed even for auto_maintained topics.
CREATE OR REPLACE FUNCTION public.join_topic (p_user_id uuid, p_topic_id uuid)
    RETURNS void LANGUAGE plpgsql SET search_path TO 'public' AS $$
DECLARE v_primary uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM topic WHERE id = p_topic_id) THEN RAISE EXCEPTION 'Topic not found'; END IF;
    DELETE FROM topic_member_optout WHERE topic_id = p_topic_id AND user_id = p_user_id;
    SELECT uc.contact_id INTO v_primary FROM user_contact uc
    WHERE uc.user_id = p_user_id AND uc.linked = TRUE AND uc.archived_at IS NULL
    ORDER BY uc.primary DESC NULLS LAST, uc.created_at ASC LIMIT 1;
    IF v_primary IS NOT NULL THEN
        INSERT INTO topic_contact (topic_id, contact_id) VALUES (p_topic_id, v_primary) ON CONFLICT DO NOTHING;
    END IF;
END;
$$;

-- leave: the universal opt-out (works regardless of how the user is a member).
CREATE OR REPLACE FUNCTION public.leave_topic (p_user_id uuid, p_topic_id uuid)
    RETURNS void LANGUAGE plpgsql SET search_path TO 'public' AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM topic WHERE id = p_topic_id) THEN RAISE EXCEPTION 'Topic not found'; END IF;
    INSERT INTO topic_member_optout (topic_id, user_id) VALUES (p_topic_id, p_user_id) ON CONFLICT DO NOTHING;
END;
$$;
