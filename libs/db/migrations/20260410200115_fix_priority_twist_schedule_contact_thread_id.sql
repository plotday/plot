-- Modify "priority_twist_schedule_contact" view
CREATE OR REPLACE VIEW "public"."priority_twist_schedule_contact" (
  "priority_twist_id",
  "schedule_contact_id",
  "schedule_id",
  "contact_id",
  "status",
  "role",
  "archived_at",
  "thread_id",
  "link_id",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS priority_twist_id,
    sc.id AS schedule_contact_id,
    sc.schedule_id,
    sc.contact_id,
    sc.status,
    sc.role,
    sc.archived_at,
    a.id AS thread_id,
    s.link_id,
    sc.updated_at,
    a.priority_id
   FROM public.priority_twist pt
     JOIN public.thread a ON a.created_by = pt.id
     JOIN public.link l ON l.thread_id = a.id AND l.created_by = pt.id
     JOIN public.schedule s ON s.link_id = l.id
     JOIN public.schedule_contact sc ON sc.schedule_id = s.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND sc.updated_at > pt.created_at
  ORDER BY sc.updated_at;
