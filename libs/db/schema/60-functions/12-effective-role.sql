-- Returns the effective role for a user on a priority. The viewer role
-- went away with the old sharing model; in the per-user model the
-- owner is always 'member' and anyone else gets NULL.
CREATE OR REPLACE FUNCTION "user".get_effective_role (p_user_id uuid, p_priority_id uuid)
    RETURNS text
    LANGUAGE sql
    STABLE
    SET search_path TO 'public'
    AS $$
    SELECT CASE
        WHEN EXISTS (
            SELECT 1 FROM priority p
            WHERE p.id = p_priority_id
              AND p.user_id = p_user_id
              AND p.archived_at IS NULL
        ) THEN 'member'
        ELSE NULL
    END
$$;
