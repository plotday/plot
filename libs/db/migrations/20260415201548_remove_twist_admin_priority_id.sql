-- Create "get_accessible_twists" function
CREATE OR REPLACE FUNCTION "public"."get_accessible_twists" ("p_user_id" uuid) RETURNS SETOF "public"."twist" LANGUAGE sql STABLE AS $$
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
            OR (twist.environment = 'review'
                AND EXISTS (SELECT 1 FROM twist_reviewer WHERE user_id = p_user_id))
            OR EXISTS (
                SELECT 1 FROM topic t
                JOIN topic_member tm ON tm.topic_id = t.id
                JOIN user_contact uc ON uc.contact_id = tm.contact_id
                WHERE t.auto_twist_admin_id = twist_admin.id
                  AND t.auto_maintained = TRUE
                  AND uc.user_id = p_user_id
                  AND uc.linked = TRUE
                  AND uc.archived_at IS NULL
            )
        )
$$;
-- Create "is_accessible_twist" function
CREATE OR REPLACE FUNCTION "public"."is_accessible_twist" ("p_twist_id" bigint, "p_user_id" uuid) RETURNS boolean LANGUAGE sql STABLE AS $$
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
                    OR (twist.environment = 'review'
                        AND EXISTS (SELECT 1 FROM twist_reviewer WHERE user_id = p_user_id))
                    OR EXISTS (
                        SELECT 1 FROM topic t
                        JOIN topic_member tm ON tm.topic_id = t.id
                        JOIN user_contact uc ON uc.contact_id = tm.contact_id
                        WHERE t.auto_twist_admin_id = twist_admin.id
                          AND t.auto_maintained = TRUE
                          AND uc.user_id = p_user_id
                          AND uc.linked = TRUE
                          AND uc.archived_at IS NULL
                    )))
$$;
