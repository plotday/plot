-- Create "note_reactions" view
CREATE VIEW "user"."note_reactions" (
  "user_id",
  "id",
  "updated_at",
  "seq",
  "archived_at",
  "priority_id",
  "priority_path",
  "reactions"
) AS SELECT ua.user_id,
    n.id,
    nr.updated_at,
    nr.seq,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nr.reactions
   FROM "user".thread ua
     JOIN public.note n ON n.thread_id = ua.id
     JOIN LATERAL ( SELECT jsonb_object_agg(sq.emoji, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS reactions,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT nr_1.emoji,
                    jsonb_agg(nr_1.actor_id ORDER BY nr_1.actor_id) FILTER (WHERE nr_1.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(nr_1.archived_at, nr_1.updated_at)) AS updated_at,
                    max(nr_1.seq) AS seq
                   FROM public.note_reaction nr_1
                  WHERE nr_1.note_id = n.id
                  GROUP BY nr_1.emoji) sq
         HAVING count(*) > 0) nr ON true
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.access_contacts IS NULL OR n.created_by = ua.user_id OR n.access_contacts && "user".user_contact_ids(ua.user_id));
-- Create "thread_reactions" view
CREATE VIEW "user"."thread_reactions" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "seq",
  "priority_id",
  "priority_path",
  "reactions"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    tr.occurrence,
    tr.updated_at,
    tr.seq,
    ua.priority_id,
    ua.priority_path,
    tr.reactions
   FROM "user".thread ua
     JOIN LATERAL ( SELECT sq.occurrence,
            jsonb_object_agg(sq.emoji, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS reactions,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT tr_1.occurrence,
                    tr_1.emoji,
                    jsonb_agg(tr_1.actor_id) FILTER (WHERE tr_1.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(tr_1.archived_at, tr_1.updated_at)) AS updated_at,
                    max(tr_1.seq) AS seq
                   FROM public.thread_reaction tr_1
                  WHERE tr_1.thread_id = ua.id
                  GROUP BY tr_1.occurrence, tr_1.emoji) sq
          GROUP BY sq.occurrence) tr ON true;
