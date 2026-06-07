-- Modify "twist_instance_note_reaction_change" view
CREATE OR REPLACE VIEW "public"."twist_instance_note_reaction_change" (
  "twist_instance_id",
  "id",
  "note_id",
  "thread_id",
  "actor_id",
  "emoji",
  "archived_at",
  "updated_at",
  "seq",
  "change_type"
) AS SELECT pt.id AS twist_instance_id,
    nr.id,
    nr.note_id,
    n.thread_id,
    nr.actor_id,
    nr.emoji,
    nr.archived_at,
    nr.updated_at,
    nr.seq,
        CASE
            WHEN nr.archived_at IS NULL THEN 'added'::text
            ELSE 'removed'::text
        END AS change_type
   FROM public.note_reaction nr
     JOIN public.note n ON n.id = nr.note_id
     JOIN public.thread a ON a.id = n.thread_id
     LEFT JOIN public.twist_instance nti ON nti.id = n.created_by
     LEFT JOIN LATERAL ( SELECT l.created_by
           FROM public.link l
             JOIN public.twist_instance lti ON lti.id = l.created_by
          WHERE l.thread_id = n.thread_id
          ORDER BY l.created_at
         LIMIT 1) src ON true
     JOIN public.twist_instance pt ON pt.id = public.twist_instance_for_actor(nr.actor_id, COALESCE(nti.id, src.created_by))
  WHERE n.draft = false AND a.draft = false AND nr.updated_at > pt.created_at;
