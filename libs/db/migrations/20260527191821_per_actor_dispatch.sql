-- Create "twist_instance_for_actor" function
CREATE FUNCTION "public"."twist_instance_for_actor" ("p_actor_contact_id" uuid, "p_reference_twist_instance_id" uuid) RETURNS uuid LANGUAGE sql STABLE AS $$
SELECT pt.id
    FROM twist_instance pt
    JOIN user_contact uc ON uc.user_id = pt.owner_id
    WHERE pt.twist_id = (
        SELECT twist_id FROM twist_instance
        WHERE id = p_reference_twist_instance_id
    )
      AND pt.archived_at IS NULL
      AND pt.draft = FALSE
      AND uc.contact_id = p_actor_contact_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL
    LIMIT 1;
$$;
-- Modify "twist_instance_schedule_contact" view
CREATE OR REPLACE VIEW "public"."twist_instance_schedule_contact" (
  "twist_instance_id",
  "schedule_contact_id",
  "schedule_id",
  "contact_id",
  "status",
  "role",
  "archived_at",
  "thread_id",
  "link_id",
  "updated_at",
  "seq",
  "priority_id"
) AS SELECT pt.id AS twist_instance_id,
    sc.id AS schedule_contact_id,
    sc.schedule_id,
    sc.contact_id,
    sc.status,
    sc.role,
    sc.archived_at,
    s.thread_id,
    s.link_id,
    sc.updated_at,
    sc.seq,
    tp.priority_id
   FROM public.schedule_contact sc
     JOIN public.schedule s ON s.id = sc.schedule_id
     JOIN public.link l ON l.id = s.link_id
     JOIN public.thread a ON a.id = l.thread_id
     JOIN public.twist_instance pt ON pt.id = public.twist_instance_for_actor(sc.contact_id, l.created_by)
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
  WHERE a.draft = false AND sc.updated_at > pt.created_at
  ORDER BY sc.updated_at;
