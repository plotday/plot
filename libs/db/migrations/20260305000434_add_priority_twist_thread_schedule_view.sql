-- Create "priority_twist_thread_schedule" view
CREATE VIEW "public"."priority_twist_thread_schedule" (
  "priority_twist_id",
  "thread_id",
  "schedule_id",
  "user_id",
  "on",
  "at",
  "done_at",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS priority_twist_id,
    s.thread_id,
    s.id AS schedule_id,
    s.user_id,
    s."on",
    s.at,
    s.done_at,
    s.updated_at,
    a.priority_id
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     JOIN public.schedule s ON s.thread_id = a.id
  WHERE a.draft = false AND pt.id = a.created_by AND pt.archived_at IS NULL AND s.user_id IS NOT NULL AND s.archived_at IS NULL AND s.updated_at > pt.created_at
  ORDER BY s.updated_at;
