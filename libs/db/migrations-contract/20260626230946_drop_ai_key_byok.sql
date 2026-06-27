-- Modify "ai_preference" table
ALTER TABLE "public"."ai_preference" DROP COLUMN "builtin_ai_key_id", DROP COLUMN "twist_ai_key_id";
-- Drop "ai_key" table
DROP TABLE "public"."ai_key";
