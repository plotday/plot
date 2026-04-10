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
    s.thread_id,
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
-- Modify "priority_twist_thread_read" view
CREATE OR REPLACE VIEW "public"."priority_twist_thread_read" (
  "priority_twist_id",
  "thread_id",
  "user_id",
  "read_at",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS priority_twist_id,
    tu.thread_id,
    tu.user_id,
    tu.read_at,
    tu.updated_at,
    a.priority_id
   FROM public.priority_twist pt
     JOIN public.thread a ON a.created_by = pt.id
     JOIN public.thread_unread tu ON tu.thread_id = a.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND tu.read_at IS NOT NULL AND tu.updated_at > pt.created_at
  ORDER BY tu.updated_at;
-- Modify "priority_twist_thread_schedule" view
CREATE OR REPLACE VIEW "public"."priority_twist_thread_schedule" (
  "priority_twist_id",
  "thread_id",
  "schedule_id",
  "user_id",
  "on",
  "at",
  "updated_at",
  "priority_id"
) AS SELECT a.created_by AS priority_twist_id,
    s.thread_id,
    s.id AS schedule_id,
    s.user_id,
    s."on",
    s.at,
    s.updated_at,
    a.priority_id
   FROM public.priority_twist pt
     JOIN public.thread a ON a.created_by = pt.id
     JOIN public.schedule s ON s.thread_id = a.id
  WHERE a.draft = false AND pt.archived_at IS NULL AND s.user_id IS NOT NULL AND s.archived_at IS NULL AND s.updated_at > pt.created_at
  ORDER BY s.updated_at;
-- Modify "priority_twist_thread_update" view
CREATE OR REPLACE VIEW "public"."priority_twist_thread_update" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "draft",
  "access",
  "access_contacts",
  "title",
  "preview",
  "priority_title",
  "tags"
) AS SELECT a.created_by AS priority_twist_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.created_by,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.draft,
    a.access,
    a.access_contacts,
    a.title,
    a.preview,
    pc.title AS priority_title,
    at.tags
   FROM public.priority_twist pt
     JOIN public.thread a ON a.created_by = pt.id
     LEFT JOIN public.priority pc ON pc.id = a.priority_id
     LEFT JOIN public.thread_tags at ON at.thread_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > a.created_at AND public.updated_by_uuid(pt.id) <> a.updated_by::numeric AND pt.archived_at IS NULL AND GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > pt.created_at
  ORDER BY (GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)));
