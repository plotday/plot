-- Returns the id of the user's root priority (the depth-1, non-archived
-- priority that the activate_invited_user flow creates exactly one of per
-- user). Used by views to surface case-A pending thread_priority rows
-- (priority_id NULL, classify_at past the visibility window) at the
-- user's root until the consumer Worker resolves the classification.
CREATE OR REPLACE FUNCTION "user".root_priority_id (p_user_id uuid)
    RETURNS uuid
    LANGUAGE sql
    STABLE
    AS $$
    SELECT p.id
    FROM priority p
    WHERE p.user_id = p_user_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;
$$;
