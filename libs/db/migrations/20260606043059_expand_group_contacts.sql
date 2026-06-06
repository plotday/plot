-- Create "expand_group_contacts" function
CREATE FUNCTION "public"."expand_group_contacts" ("p_user_id" uuid, "p_group_id" uuid) RETURNS uuid[] LANGUAGE plpgsql STABLE SET "search_path" = public AS $$
DECLARE
    v_group RECORD;
BEGIN
    SELECT * INTO v_group FROM "group" WHERE id = p_group_id;
    IF v_group IS NULL THEN
        RAISE EXCEPTION 'Group not found';
    END IF;
    IF NOT (
        EXISTS (SELECT 1 FROM group_admin WHERE group_id = p_group_id AND user_id = p_user_id)
        OR (v_group.privacy = 'open' AND EXISTS (
            SELECT 1 FROM group_member gm
            JOIN user_contact uc ON uc.contact_id = gm.contact_id
                AND uc.linked = TRUE AND uc.archived_at IS NULL
            WHERE gm.group_id = p_group_id AND uc.user_id = p_user_id))
    ) THEN
        RAISE EXCEPTION 'Insufficient permission to use this group';
    END IF;
    RETURN COALESCE(
        (SELECT array_agg(contact_id) FROM group_member WHERE group_id = p_group_id),
        ARRAY[]::uuid[]
    );
END;
$$;
