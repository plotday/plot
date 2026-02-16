-- Create "get_users_with_priority_access" function
CREATE FUNCTION "public"."get_users_with_priority_access" ("target_priority_id" uuid) RETURNS TABLE ("user_id" uuid) LANGUAGE sql STABLE SET "search_path" = public AS $$
SELECT DISTINCT
        pu.user_id
    FROM
        priority_user pu
        JOIN priority pp ON pu.priority_id = pp.id
        JOIN priority p ON p.path <@ pp.path
    WHERE
        pu.archived_at IS NULL
        AND p.id = target_priority_id
$$;
-- Create "has_priority_access" function
CREATE FUNCTION "user"."has_priority_access" ("user_id" uuid, "priority_id" uuid) RETURNS boolean LANGUAGE sql STABLE SET "search_path" = public AS $$
SELECT
        public.user_has_priority_access (user_id, priority_id)
$$;
