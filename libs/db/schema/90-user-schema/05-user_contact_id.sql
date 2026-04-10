CREATE OR REPLACE FUNCTION "user".user_contact_id (p_user_id uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $$
    SELECT c.id FROM contact c WHERE c.user_id = p_user_id AND c."primary" = TRUE LIMIT 1;
$$;

-- Returns every non-archived contact linked to the user. Access checks and
-- count-tag ownership must use this so a user can access threads (and modify
-- their own tags) through any of their linked contacts, not just the primary.
CREATE OR REPLACE FUNCTION "user".user_contact_ids (p_user_id uuid)
    RETURNS uuid[]
    LANGUAGE sql
    STABLE
    AS $$
    SELECT COALESCE(array_agg(c.id), ARRAY[]::uuid[])
    FROM contact c
    WHERE c.user_id = p_user_id AND c.archived_at IS NULL;
$$;
