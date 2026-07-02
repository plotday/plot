-- Modify "twist_instance_thread_read" view
CREATE OR REPLACE VIEW "public"."twist_instance_thread_read" (
  "twist_instance_id",
  "thread_id",
  "user_id",
  "read_at",
  "updated_at",
  "seq",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    tu.thread_id,
    tu.user_id,
    tu.read_at,
    tu.updated_at,
    COALESCE(tu.read_seq, tu.seq) AS seq,
    tp.priority_id
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     JOIN public.thread_state tu ON tu.thread_id = a.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND tu.updated_at > pt.created_at AND tu.read_source IS DISTINCT FROM pt.id
  ORDER BY (COALESCE(tu.read_seq, tu.seq));
-- Modify "twist_instance_thread_schedule" view
CREATE OR REPLACE VIEW "public"."twist_instance_thread_schedule" (
  "twist_instance_id",
  "thread_id",
  "user_id",
  "on",
  "at",
  "active",
  "read_at",
  "updated_at",
  "seq",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    ts.thread_id,
    ts.user_id,
    ts."on",
    ts.at,
    ts.active,
    ts.read_at,
    ts.updated_at,
    COALESCE(ts.todo_seq, ts.seq) AS seq,
    tp.priority_id
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     JOIN public.thread_state ts ON ts.thread_id = a.id AND ts.user_id = pt.owner_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
  WHERE a.draft = false AND pt.archived_at IS NULL AND ts.updated_at > pt.created_at AND ts.todo_source IS DISTINCT FROM pt.id
  ORDER BY (COALESCE(ts.todo_seq, ts.seq));
