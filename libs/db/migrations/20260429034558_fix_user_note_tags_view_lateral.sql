-- Modify "note_tags" view
CREATE OR REPLACE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "seq",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    nt.seq,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM "user".thread ua
     JOIN public.note n ON n.thread_id = ua.id
     JOIN LATERAL ( SELECT jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT nt_1.tag_id,
                    jsonb_agg(nt_1.actor_id ORDER BY nt_1.actor_id) FILTER (WHERE nt_1.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(nt_1.archived_at, nt_1.updated_at)) AS updated_at,
                    max(nt_1.seq) AS seq
                   FROM public.note_tag nt_1
                  WHERE nt_1.note_id = n.id
                  GROUP BY nt_1.tag_id) sq
         HAVING count(*) > 0) nt ON true
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.access_contacts IS NULL OR n.created_by = ua.user_id OR n.access_contacts && "user".user_contact_ids(ua.user_id));
