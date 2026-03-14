-- Drop "source_channel" view
DROP VIEW "user"."source_channel";
-- Modify "source_channel" table
ALTER TABLE "public"."source_channel" ALTER COLUMN "create_threads" TYPE text, ALTER COLUMN "create_threads" SET DEFAULT 'all';
-- Migrate existing boolean text values to enum strings
UPDATE "public"."source_channel" SET create_threads = CASE WHEN create_threads = 'true' THEN 'all' ELSE 'manual' END WHERE create_threads IN ('true', 'false');
-- Create "source_channel" view
CREATE VIEW "user"."source_channel" (
  "user_id",
  "id",
  "priority_twist_id",
  "channel_id",
  "title",
  "priority_id",
  "enabled",
  "create_threads",
  "created_at",
  "updated_at"
) AS SELECT pt.owner_id AS user_id,
    sc.id,
    sc.priority_twist_id,
    sc.channel_id,
    sc.title,
    sc.priority_id,
    sc.enabled,
    sc.create_threads,
    sc.created_at,
    sc.updated_at
   FROM public.source_channel sc
     JOIN public.priority_twist pt ON pt.id = sc.priority_twist_id;
