-- Modify "get_accessible_twists" function
CREATE OR REPLACE FUNCTION "public"."get_accessible_twists" ("p_priority_id" uuid, "p_user_id" uuid) RETURNS SETOF "public"."twist" LANGUAGE sql STABLE AS $$
SELECT DISTINCT
        twist.*
    FROM
        twist
        JOIN twist_admin ON twist.twist_admin_id = twist_admin.id
    WHERE
        twist.archived_at IS NULL
        AND (
            twist.environment = 'public'
            OR (twist.environment = 'personal'
                AND twist_admin.user_id = p_user_id)
            OR user_has_priority_access (p_user_id, twist_admin.priority_id)
        )
$$;
-- Modify "is_accessible_twist" function
CREATE OR REPLACE FUNCTION "public"."is_accessible_twist" ("p_twist_id" bigint, "p_priority_id" uuid, "p_user_id" uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
SELECT
        EXISTS (
            SELECT
                1
            FROM
                twist
                JOIN twist_admin ON twist.twist_admin_id = twist_admin.id
            WHERE
                twist.id = p_twist_id
                AND twist.archived_at IS NULL
                AND (twist.environment = 'public'
                    OR (twist.environment = 'personal'
                        AND twist_admin.user_id = p_user_id)
                    OR user_has_priority_access (p_user_id, twist_admin.priority_id)))
$$;
