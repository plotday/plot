-- Whether the user may ADDRESS a group (add it to a thread/topic, or expand it
-- to recipients): admins always; otherwise only members of an `open`-privacy
-- group. Mirrors user.group.can_address. Single source of truth for the
-- "can this user use this group" check.
CREATE OR REPLACE FUNCTION public.user_can_address_group (p_user_id uuid, p_group_id uuid)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SET search_path TO 'public'
    AS $$
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

-- Snapshot a group to its member contact_ids — but only if the caller may
-- ADDRESS the group (admin OR an `open`-privacy member, mirroring
-- user.group.can_address). Used to expand a group to recipients when composing
-- a connector (Gmail/Slack) thread, where membership can't be tracked live.
CREATE OR REPLACE FUNCTION public.expand_group_contacts (p_user_id uuid, p_group_id uuid)
    RETURNS uuid[]
    LANGUAGE plpgsql
    STABLE
    SET search_path TO 'public'
    AS $$
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
