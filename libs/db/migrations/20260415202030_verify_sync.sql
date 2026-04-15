-- Modify "twist_admin" table
ALTER TABLE "public"."twist_admin" DROP COLUMN IF EXISTS "priority_id";
-- Drop "get_accessible_twists" function (old 2-arg signature)
DROP FUNCTION IF EXISTS "public"."get_accessible_twists" (uuid, uuid);
-- Drop "is_accessible_twist" function (old 3-arg signature)
DROP FUNCTION IF EXISTS "public"."is_accessible_twist" (bigint, uuid, uuid);
