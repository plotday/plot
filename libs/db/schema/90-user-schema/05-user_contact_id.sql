-- Returns the user's primary linked contact, or NULL if none is set.
CREATE OR REPLACE FUNCTION "user".user_contact_id (p_user_id uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $$
    SELECT uc.contact_id
    FROM user_contact uc
    WHERE uc.user_id = p_user_id
      AND uc."primary" = TRUE
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL
    LIMIT 1;
$$;

-- Returns every non-archived contact linked to the user. Access checks and
-- count-tag ownership must use this so a user can access threads (and modify
-- their own tags) through any of their linked contacts, not just the primary.
CREATE OR REPLACE FUNCTION "user".user_contact_ids (p_user_id uuid)
    RETURNS uuid[]
    LANGUAGE sql
    STABLE
    AS $$
    SELECT COALESCE(array_agg(uc.contact_id), ARRAY[]::uuid[])
    FROM user_contact uc
    WHERE uc.user_id = p_user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;
$$;
