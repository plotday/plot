-- Modify "assert_priority_access" function
CREATE OR REPLACE FUNCTION "user"."assert_priority_access" ("user_id" uuid, "priority_id" uuid) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
BEGIN
    IF priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM priority p
        WHERE p.id = assert_priority_access.priority_id
          AND p.user_id = assert_priority_access.user_id
    ) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
END;
$$;
