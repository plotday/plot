-- Create "twist_reviewer" table
CREATE TABLE "public"."twist_reviewer" (
  "user_id" uuid NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("user_id"),
  CONSTRAINT "twist_reviewer_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
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
            OR (twist.environment = 'review'
                AND EXISTS (SELECT 1 FROM twist_reviewer WHERE user_id = p_user_id))
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
                    OR (twist.environment = 'review'
                        AND EXISTS (SELECT 1 FROM twist_reviewer WHERE user_id = p_user_id))
                    OR user_has_priority_access (p_user_id, twist_admin.priority_id)))
$$;
