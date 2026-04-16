CREATE OR REPLACE FUNCTION "user".user_group_ids (p_user_id uuid)
    RETURNS uuid[]
    LANGUAGE sql
    STABLE
    AS $$
    SELECT COALESCE(array_agg(DISTINCT gm.group_id), ARRAY[]::uuid[])
    FROM group_member gm
    JOIN user_contact uc ON uc.contact_id = gm.contact_id
        AND uc.linked = TRUE
        AND uc.archived_at IS NULL
    WHERE uc.user_id = p_user_id;
$$;
