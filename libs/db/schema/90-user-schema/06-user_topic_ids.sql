CREATE OR REPLACE FUNCTION "user".user_topic_ids (p_user_id uuid)
    RETURNS uuid[]
    LANGUAGE sql
    STABLE
    AS $$
    SELECT COALESCE(array_agg(DISTINCT tm.topic_id), ARRAY[]::uuid[])
    FROM topic_member tm
    JOIN user_contact uc ON uc.contact_id = tm.contact_id
        AND uc.linked = TRUE
        AND uc.archived_at IS NULL
    WHERE uc.user_id = p_user_id;
$$;
