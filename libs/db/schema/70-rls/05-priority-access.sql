-- Function to check if a user has access to a priority
-- This extracts the common logic used in RLS policies
CREATE OR REPLACE FUNCTION public.user_has_priority_access (user_id uuid, target_priority_id uuid)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    AS $$
BEGIN
    RETURN EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority p ON pu.priority_id = p.id
                OR (p.path <@ (
                        SELECT
                            path
                        FROM
                            priority
                    WHERE
                        id = pu.priority_id))
            WHERE
                pu.user_id = user_has_priority_access.user_id
                AND pu.deleted_at IS NULL
                AND p.id = user_has_priority_access.target_priority_id);
END;
$$;

-- Function to get all users who have access to a priority
-- Used for notifications
CREATE OR REPLACE FUNCTION public.get_users_with_priority_access (target_priority_id uuid)
    RETURNS TABLE (
        user_id uuid)
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY SELECT DISTINCT
        pu.user_id
    FROM
        priority_user pu
        JOIN priority p ON pu.priority_id = p.id
            OR (p.path <@ (
                    SELECT
                        path
                    FROM
                        priority
                WHERE
                    id = pu.priority_id))
    WHERE
        pu.deleted_at IS NULL
        AND p.id = get_users_with_priority_access.target_priority_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.user_has_priority_access (user_id uuid, target_priority_path ltree)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    AS $$
BEGIN
    PERFORM
        set_config('row_security', 'off', TRUE);
    RETURN EXISTS (
        SELECT
            1
        FROM
            priority_user pu
            JOIN priority pp ON pu.priority_id = pp.id
            JOIN priority p ON p.path <@ pp.path
        WHERE
            pu.user_id = user_has_priority_access.user_id
            AND pu.deleted_at IS NULL
            AND p.path = user_has_priority_access.target_priority_path);
END;
$$;

CREATE FUNCTION can_access_priority (_priority_id uuid)
    RETURNS bool
    AS $$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.priority_user cu
                JOIN public.priority c ON c.id = cu.priority_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.priority c2
                    WHERE
                        c2.id = _priority_id))
            OR NOT EXISTS (
                SELECT
                    1
                FROM
                    public.priority_user cu
                WHERE
                    cu.priority_id = _priority_id);
$$
LANGUAGE sql
SECURITY DEFINER;

CREATE FUNCTION can_access_priority (_priority_path ltree)
    RETURNS bool
    AS $$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.priority_user cu
                JOIN public.priority c ON c.id = cu.priority_id
            WHERE
                cu.user_id = auth.uid ()
                AND c.path @> (
                    SELECT
                        path
                    FROM
                        public.priority c2
                    WHERE
                        c2.path = _priority_path));
$$
LANGUAGE sql
SECURITY DEFINER;

