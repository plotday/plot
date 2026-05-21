-- Modify "schedule" view
CREATE OR REPLACE VIEW "user"."schedule" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "schedule_user_id",
  "order",
  "at",
  "on",
  "recurrence_rule",
  "duration",
  "recurrence_exdates",
  "occurrence",
  "thread_id",
  "link_id",
  "reason",
  "outstanding_tasks",
  "priority_path",
  "range_at",
  "range_on",
  "contacts"
) AS SELECT tp.user_id,
    s.id,
    s.created_at,
    s.updated_at,
    s.seq,
    COALESCE(s.archived_at, upe.archived_at) AS archived_at,
    s.user_id AS schedule_user_id,
    s."order",
    s.at,
    s."on",
    s.recurrence_rule,
    s.duration,
    s.recurrence_exdates,
    s.occurrence,
    s.thread_id,
    s.link_id,
    s.reason,
    s.outstanding_tasks,
    upe.path AS priority_path,
        CASE
            WHEN s.at IS NOT NULL THEN s.at
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN s."on" IS NOT NULL THEN s."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', sc.id, 'contact_id', sc.contact_id, 'contact_email', c.email, 'contact_name', c.name, 'contact_user_id', c.user_id, 'status', sc.status, 'role', sc.role, 'archived_at', sc.archived_at, 'updated_at', sc.updated_at) ORDER BY sc.created_at) AS jsonb_agg
           FROM public.schedule_contact sc
             JOIN public.contact c ON c.id = sc.contact_id
          WHERE sc.schedule_id = s.id), '[]'::jsonb) AS contacts
   FROM public.schedule s
     LEFT JOIN public.link l ON l.id = s.link_id
     JOIN public.thread_priority tp ON tp.thread_id = COALESCE(s.thread_id, l.thread_id) AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window()))
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
  WHERE s.user_id IS NULL OR s.user_id = tp.user_id;
