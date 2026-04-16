-- Create a new group. Creator automatically becomes admin.
CREATE OR REPLACE FUNCTION public.create_group (
    p_user_id uuid,
    p_name text,
    p_type group_type DEFAULT 'private',
    p_join_policy group_join_policy DEFAULT 'member',
    p_team_id bigint DEFAULT NULL,
    p_member_contact_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
    RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_group_id uuid;
BEGIN
    IF p_team_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM team_user
            WHERE team_id = p_team_id AND user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'User is not a member of this team';
        END IF;
    END IF;

    INSERT INTO "group" (name, type, join_policy, team_id, created_by)
    VALUES (p_name, p_type, p_join_policy, p_team_id, p_user_id)
    RETURNING id INTO v_group_id;

    INSERT INTO group_admin (group_id, user_id)
    VALUES (v_group_id, p_user_id);

    IF cardinality(p_member_contact_ids) > 0 THEN
        INSERT INTO group_member (group_id, contact_id)
        SELECT v_group_id, unnest(p_member_contact_ids)
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_group_id;
END;
$function$;

-- Add contacts to a group's member list.
CREATE OR REPLACE FUNCTION public.add_group_members (
    p_user_id uuid,
    p_group_id uuid,
    p_contact_ids uuid[]
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_group RECORD;
BEGIN
    SELECT * INTO v_group FROM "group" WHERE id = p_group_id;
    IF v_group IS NULL THEN
        RAISE EXCEPTION 'Group not found';
    END IF;
    IF v_group.auto_maintained THEN
        RAISE EXCEPTION 'Cannot modify members of auto-maintained group';
    END IF;

    IF v_group.join_policy = 'admin' THEN
        IF NOT EXISTS (
            SELECT 1 FROM group_admin
            WHERE group_id = p_group_id AND user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'Only admins can add members to this group';
        END IF;
    ELSIF v_group.join_policy = 'member' THEN
        IF NOT EXISTS (
            SELECT 1 FROM group_admin
            WHERE group_id = p_group_id AND user_id = p_user_id
        ) AND NOT EXISTS (
            SELECT 1 FROM group_member gm
            JOIN user_contact uc ON uc.contact_id = gm.contact_id
                AND uc.linked = TRUE AND uc.archived_at IS NULL
            WHERE gm.group_id = p_group_id AND uc.user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'Only members can add members to this group';
        END IF;
    END IF;

    INSERT INTO group_member (group_id, contact_id)
    SELECT p_group_id, unnest(p_contact_ids)
    ON CONFLICT DO NOTHING;
END;
$function$;

-- Remove contacts from a group's member list.
CREATE OR REPLACE FUNCTION public.remove_group_members (
    p_user_id uuid,
    p_group_id uuid,
    p_contact_ids uuid[]
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_group RECORD;
BEGIN
    SELECT * INTO v_group FROM "group" WHERE id = p_group_id;
    IF v_group IS NULL THEN
        RAISE EXCEPTION 'Group not found';
    END IF;
    IF v_group.auto_maintained THEN
        RAISE EXCEPTION 'Cannot modify members of auto-maintained group';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM group_admin
        WHERE group_id = p_group_id AND user_id = p_user_id
    ) AND NOT EXISTS (
        SELECT 1 FROM group_member gm
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE gm.group_id = p_group_id AND uc.user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'Insufficient permission to remove group members';
    END IF;

    DELETE FROM group_member
    WHERE group_id = p_group_id AND contact_id = ANY(p_contact_ids);
END;
$function$;
