-- Check if a user has access to a priority (via priority_user hierarchy)
-- Respects inherit_members boundaries: if a descendant has inherit_members=FALSE,
-- parent's priority_user entries do not grant access to it or its descendants.
CREATE OR REPLACE FUNCTION public.user_has_priority_access (p_user_id uuid, p_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path TO 'public'
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
                            AND blocker.inherit_members = FALSE)))
$function$;
