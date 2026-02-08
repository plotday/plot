-- Function to check if a user has access to a priority
-- This extracts the common logic used in RLS policies
CREATE OR REPLACE FUNCTION public.user_has_priority_access (user_id uuid, target_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority_user pu
                JOIN priority pp ON pu.priority_id = pp.id
                JOIN priority p ON p.path <@ pp.path
            WHERE
                pu.user_id = user_has_priority_access.user_id
                AND pu.archived_at IS NULL
                AND p.id = user_has_priority_access.target_priority_id);
$function$;

-- Function to get all users who have access to a priority
-- Used for notifications
CREATE OR REPLACE FUNCTION public.get_users_with_priority_access (target_priority_id uuid)
    RETURNS TABLE (
        user_id uuid)
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT DISTINCT
        pu.user_id
    FROM
        priority_user pu
        JOIN priority pp ON pu.priority_id = pp.id
        JOIN priority p ON p.path <@ pp.path
    WHERE
        pu.archived_at IS NULL
        AND p.id = get_users_with_priority_access.target_priority_id;
$function$;

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
            AND pu.archived_at IS NULL
            AND p.path = user_has_priority_access.target_priority_path);
END;
$$;

CREATE OR REPLACE FUNCTION public.can_access_priority (_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority_user pu
                JOIN priority pp ON pu.priority_id = pp.id
                JOIN priority p ON p.path <@ pp.path
            WHERE
                pu.user_id = (
                    SELECT
                        auth.uid ())
                    AND pu.archived_at IS NULL
                    AND p.id = _priority_id);
$function$;

CREATE OR REPLACE FUNCTION public.can_access_priority (_priority_path ltree)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.priority_user pu
                JOIN public.priority p ON p.id = pu.priority_id
            WHERE
                pu.user_id = (
                    SELECT
                        auth.uid ())
                    AND pu.archived_at IS NULL
                    AND p.path @> _priority_path);
$function$;

-- Restrict access: only service_role can call this function
-- This function exposes user access information
REVOKE EXECUTE ON FUNCTION public.get_users_with_priority_access (uuid) FROM PUBLIC;

