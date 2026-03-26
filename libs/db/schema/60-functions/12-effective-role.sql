-- Returns the effective role for a user on a priority
-- Most-permissive-wins: if user has 'member' on any ancestor priority_user, returns 'member'
-- Otherwise returns the role from the most specific priority_user entry
-- Returns NULL if no access
-- Respects inherit_members boundaries.
CREATE OR REPLACE FUNCTION "user".get_effective_role (p_user_id uuid, p_priority_id uuid)
    RETURNS text
    LANGUAGE sql
    STABLE
    SET search_path TO 'public'
    AS $$
    SELECT
        CASE WHEN bool_or(pu.role = 'member') THEN
            'member'
        ELSE
            COALESCE(MAX(pu.role), NULL)
        END
    FROM
        priority_user pu
        JOIN priority pp ON pu.priority_id = pp.id
        JOIN priority p ON p.path <@ pp.path
    WHERE
        pu.user_id = p_user_id
        AND pu.archived_at IS NULL
        AND p.id = p_priority_id
        AND (p.id = pp.id
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    priority blocker
                WHERE
                    blocker.path <@ pp.path
                    AND p.path <@ blocker.path
                    AND blocker.path != pp.path
                    AND blocker.inherit_members = FALSE))
$$;
