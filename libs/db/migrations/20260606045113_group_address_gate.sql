-- Create "user_can_address_group" function
CREATE FUNCTION "public"."user_can_address_group" ("p_user_id" uuid, "p_group_id" uuid) RETURNS boolean LANGUAGE plpgsql STABLE SET "search_path" = public AS $$
BEGIN
    RETURN EXISTS (SELECT 1 FROM group_admin WHERE group_id = p_group_id AND user_id = p_user_id)
        OR EXISTS (
            SELECT 1 FROM "group" g
            WHERE g.id = p_group_id AND g.privacy = 'open'
              AND EXISTS (
                  SELECT 1 FROM group_member gm
                  JOIN user_contact uc ON uc.contact_id = gm.contact_id
                      AND uc.linked = TRUE AND uc.archived_at IS NULL
                  WHERE gm.group_id = p_group_id AND uc.user_id = p_user_id)
        );
END;
$$;
-- Modify "add_topic_groups" function
CREATE OR REPLACE FUNCTION "public"."add_topic_groups" ("p_user_id" uuid, "p_topic_id" uuid, "p_group_ids" uuid[]) RETURNS void LANGUAGE plpgsql SET "search_path" = public AS $$
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
-- Modify "expand_group_contacts" function
CREATE OR REPLACE FUNCTION "public"."expand_group_contacts" ("p_user_id" uuid, "p_group_id" uuid) RETURNS uuid[] LANGUAGE plpgsql STABLE SET "search_path" = public AS $$
DECLARE
    v_group RECORD;
BEGIN
    SELECT * INTO v_group FROM "group" WHERE id = p_group_id;
    IF v_group IS NULL THEN
        RAISE EXCEPTION 'Group not found';
    END IF;
    IF NOT public.user_can_address_group(p_user_id, p_group_id) THEN
        RAISE EXCEPTION 'Insufficient permission to use this group';
    END IF;
    RETURN COALESCE(
        (SELECT array_agg(contact_id) FROM group_member WHERE group_id = p_group_id),
        ARRAY[]::uuid[]
    );
END;
$$;
