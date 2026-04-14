-- Drop "channel" view
DROP VIEW "user"."channel";
-- Modify "channel" table
ALTER TABLE "public"."channel" DROP COLUMN "create_threads", DROP COLUMN "create_threads_by_type";
-- Create "channel" view
CREATE VIEW "user"."channel" (
  "user_id",
  "id",
  "twist_instance_id",
  "channel_id",
  "title",
  "priority_id",
  "enabled",
  "link_types",
  "created_at",
  "updated_at"
) AS SELECT pt.owner_id AS user_id,
    sc.id,
    sc.twist_instance_id,
    sc.channel_id,
    sc.title,
    sc.priority_id,
    sc.enabled,
    sc.link_types,
    sc.created_at,
    sc.updated_at
   FROM public.channel sc
     JOIN public.twist_instance pt ON pt.id = sc.twist_instance_id;
