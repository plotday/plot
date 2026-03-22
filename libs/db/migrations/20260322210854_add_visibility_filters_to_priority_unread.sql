-- Modify "priority_unread" view
CREATE OR REPLACE VIEW "user"."priority_unread" (
  "user_id",
  "priority_id",
  "unread",
  "updated_at"
) AS SELECT upe.user_id,
    upe.priority_id,
    true AS unread,
    max(tu.updated_at) AS updated_at
   FROM "user".priority_expanded upe
     JOIN public.thread a ON a.priority_id = upe.priority_id AND a.archived_at IS NULL AND (a.draft = false OR a.created_by = upe.user_id) AND (a.private = false OR a.created_by = upe.user_id OR "user".mentioned_in_thread(upe.user_id, a.id))
     JOIN public.thread_unread tu ON tu.user_id = upe.user_id AND tu.thread_id = a.id AND tu.read_at IS NULL
  GROUP BY upe.user_id, upe.priority_id;
