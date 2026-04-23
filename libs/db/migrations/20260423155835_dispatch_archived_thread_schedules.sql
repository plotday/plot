-- Drop "twist_instance_thread_schedule" view
DROP VIEW "public"."twist_instance_thread_schedule";
-- Create "twist_instance_thread_schedule" view
CREATE VIEW "public"."twist_instance_thread_schedule" (
  "twist_instance_id",
  "thread_id",
  "schedule_id",
  "user_id",
  "on",
  "at",
  "archived_at",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    s.thread_id,
    s.id AS schedule_id,
    s.user_id,
    s."on",
    s.at,
    s.archived_at,
    s.updated_at,
    tp.priority_id
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     JOIN public.schedule s ON s.thread_id = a.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND s.user_id IS NOT NULL AND s.updated_at > pt.created_at
  ORDER BY s.updated_at;
