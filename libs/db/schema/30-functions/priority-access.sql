-- Function to check if a user has access to a priority
-- This extracts the common logic used in RLS policies
CREATE OR REPLACE FUNCTION public.user_has_priority_access (user_id uuid, target_priority_id uuid)
    RETURNS boolean
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    AS $function$
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
$function$;

-- Function to get all users who have access to a priority
-- Used for notifications
CREATE OR REPLACE FUNCTION public.get_users_with_priority_access (target_priority_id uuid)
    RETURNS TABLE (
        user_id uuid)
    LANGUAGE plpgsql
    STABLE
    SECURITY DEFINER
    AS $function$
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
$function$;


