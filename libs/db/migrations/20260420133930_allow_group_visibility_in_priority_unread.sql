-- Modify "priority_unread" view
CREATE OR REPLACE VIEW "user"."priority_unread" (
  "user_id",
  "priority_id",
  "unread",
  "updated_at"
) AS SELECT tp.user_id,
    tp.priority_id,
    true AS unread,
    max(tu.updated_at) AS updated_at
   FROM public.thread_priority tp
     JOIN public.thread a ON a.id = tp.thread_id AND a.archived_at IS NULL AND tp.archived_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id))
     JOIN public.thread_unread tu ON tu.user_id = tp.user_id AND tu.thread_id = a.id AND tu.read_at IS NULL
  GROUP BY tp.user_id, tp.priority_id;
