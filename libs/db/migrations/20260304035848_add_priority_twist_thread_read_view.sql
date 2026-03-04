-- Create "priority_twist_thread_read" view
CREATE VIEW "public"."priority_twist_thread_read" (
  "priority_twist_id",
  "thread_id",
  "user_id",
  "read_at",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS priority_twist_id,
    tr.thread_id,
    tr.user_id,
    tr.read_at,
    tr.updated_at,
    a.priority_id
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.thread a ON a.priority_id = pc.id
     JOIN public.thread_read tr ON tr.thread_id = a.id
  WHERE a.draft = false AND pt.id = a.created_by AND pt.archived_at IS NULL AND tr.updated_at > pt.created_at
  ORDER BY tr.updated_at;
