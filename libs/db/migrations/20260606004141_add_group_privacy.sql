-- Create enum type "group_privacy"
CREATE TYPE "public"."group_privacy" AS ENUM ('open', 'private');
-- Modify "group" table
ALTER TABLE "public"."group" ADD COLUMN "privacy" "public"."group_privacy" NOT NULL DEFAULT 'open';
-- Backfill privacy from the legacy type: announce groups (Everyone, Plot Team)
-- are admin-only/roster-hidden -> private; all others -> open.
UPDATE "public"."group" SET privacy = 'private' WHERE type = 'announce';
