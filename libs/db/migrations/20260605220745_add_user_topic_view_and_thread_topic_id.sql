-- Create "topic" view
CREATE VIEW "user"."topic" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "name",
  "team_id",
  "announce",
  "join_policy",
  "auto_maintained",
  "key",
  "is_admin",
  "is_member",
  "opted_out",
  "can_post",
  "can_manage",
  "member_contact_ids"
) AS SELECT u.id AS user_id,
    t.id,
    t.created_at,
    t.updated_at,
    t.seq,
    t.archived_at,
    t.name,
    t.team_id,
    t.announce,
    t.join_policy,
    t.auto_maintained,
    t.key,
    (EXISTS ( SELECT 1
           FROM public.topic_admin ta
          WHERE ta.topic_id = t.id AND ta.user_id = u.id)) AS is_admin,
    t.id = ANY ("user".user_topic_ids(u.id)) AS is_member,
    (EXISTS ( SELECT 1
           FROM public.topic_member_optout o
          WHERE o.topic_id = t.id AND o.user_id = u.id)) AS opted_out,
    (EXISTS ( SELECT 1
           FROM public.topic_admin ta
          WHERE ta.topic_id = t.id AND ta.user_id = u.id)) OR t.announce = false AND (t.id = ANY ("user".user_topic_ids(u.id))) AS can_post,
    (EXISTS ( SELECT 1
           FROM public.topic_admin ta
          WHERE ta.topic_id = t.id AND ta.user_id = u.id)) OR t.join_policy = 'open'::public.topic_join_policy AND (t.id = ANY ("user".user_topic_ids(u.id))) AS can_manage,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM public.topic_admin ta
              WHERE ta.topic_id = t.id AND ta.user_id = u.id)) OR t.announce = false AND (t.id = ANY ("user".user_topic_ids(u.id))) THEN ( SELECT COALESCE(array_agg(DISTINCT roster.cid), ARRAY[]::uuid[]) AS "coalesce"
               FROM ( SELECT tc.contact_id AS cid
                       FROM public.topic_contact tc
                      WHERE tc.topic_id = t.id
                    UNION
                     SELECT gm.contact_id
                       FROM public.topic_group tg
                         JOIN public.group_member gm ON gm.group_id = tg.group_id
                      WHERE tg.topic_id = t.id) roster)
            ELSE ARRAY[]::uuid[]
        END AS member_contact_ids
   FROM public."user" u
     CROSS JOIN public.topic t
  WHERE t.archived_at IS NULL AND ((t.id = ANY ("user".user_topic_ids(u.id))) OR (EXISTS ( SELECT 1
           FROM public.topic_member_optout o
          WHERE o.topic_id = t.id AND o.user_id = u.id)) OR (EXISTS ( SELECT 1
           FROM public.topic_admin ta
          WHERE ta.topic_id = t.id AND ta.user_id = u.id)));
-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Drop "thread_reactions" view
DROP VIEW "user"."thread_reactions";
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Drop "note_reactions" view
DROP VIEW "user"."note_reactions";
-- Drop "thread" view
DROP VIEW "user"."thread";
-- Create "thread" view
CREATE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "contact_meta",
  "groups",
  "team_id",
  "topic",
  "topic_id",
  "title",
  "preview",
  "icon",
  "merged_into_thread_id",
  "has_embedding",
  "mute_by_thread_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "active",
  "urgent",
  "state_order",
  "state_on",
  "state_at",
  "activity_at",
  "agenda_at",
  "revoked"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT tp.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), tp.updated_at, COALESCE(ts.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(a.seq, a.last_note_seq, tp.seq, COALESCE(ts.seq, '0'::xid8)) AS seq,
    a.updated_by,
    COALESCE(a.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
    "user".effective_priority_id(tp.priority_id, tp.user_id) AS priority_id,
    upe.path AS priority_path,
    a.draft,
    a.contacts,
    a.contact_meta,
    a.groups,
    a.team_id,
    a.topic,
    a.topic_id,
    a.title,
    a.preview,
    a.icon,
    a.merged_into_thread_id,
    a.embedding IS NOT NULL AS has_embedding,
    tp.mute_by_thread_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    ts.bumped_at,
    COALESCE(ts.read_at IS NULL AND ts.user_id IS NOT NULL, false) AS unread,
    COALESCE(ts.importance, 0::smallint) AS importance,
    COALESCE(ts.active, false) AS active,
    ts.urgent,
    ts."order" AS state_order,
    ts."on" AS state_on,
    ts.at AS state_at,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ts.bumped_at, ( SELECT
                CASE
                    WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone) <= now() THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone)
                    ELSE NULL::timestamp with time zone
                END AS "case"
           FROM public.schedule s_feed
          WHERE s_feed.thread_id = a.id AND s_feed.occurrence IS NULL AND s_feed.archived_at IS NULL
         LIMIT 1)), a.created_at) AS activity_at,
    ( SELECT tstzrange(bounds.lo, GREATEST(bounds.lo, bounds.hi), '[]'::text) AS tstzrange
           FROM ( SELECT COALESCE(LEAST(( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), COALESCE(lower(ts.at), lower(ts."on")::timestamp with time zone), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                             JOIN public.link l_lo ON l_lo.id = s_lo.link_id
                          WHERE l_lo.thread_id = a.id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1)), a.created_at) AS lo,
                    COALESCE(
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                              WHERE s_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                                 JOIN public.link l_rec ON l_rec.id = s_rec.link_id
                              WHERE l_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) THEN 'infinity'::timestamp with time zone
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                              WHERE s_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                                 JOIN public.link l_ub ON l_ub.id = s_ub.link_id
                              WHERE l_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) THEN 'infinity'::timestamp with time zone
                            ELSE GREATEST(( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), COALESCE(upper(ts.at), upper(ts."on")::timestamp with time zone), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at,
    false AS revoked
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id)
     LEFT JOIN public.thread_state ts ON ts.user_id = tp.user_id AND ts.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE tp.revoked_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id) OR a.topic_id IS NOT NULL AND (a.topic_id = ANY ("user".user_topic_ids(tp.user_id)))) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (a.team_id IS NULL OR a.external_contacts && "user".user_contact_ids(tp.user_id) OR (EXISTS ( SELECT 1
           FROM public.team_user tu2
          WHERE tu2.team_id = a.team_id AND tu2.user_id = tp.user_id AND tu2.archived_at IS NULL)));
-- Drop "thread_redacted" view
DROP VIEW "user"."thread_redacted";
-- Create "thread_redacted" view
CREATE VIEW "user"."thread_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "contact_meta",
  "groups",
  "team_id",
  "topic",
  "topic_id",
  "title",
  "preview",
  "icon",
  "merged_into_thread_id",
  "has_embedding",
  "mute_by_thread_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "active",
  "urgent",
  "state_order",
  "state_on",
  "state_at",
  "activity_at",
  "agenda_at",
  "revoked"
) AS SELECT tp.user_id,
    a.id,
    a.created_at,
    tp.revoked_at AS updated_at,
    tp.seq,
    a.updated_by,
    tp.revoked_at AS archived_at,
    "user".effective_priority_id(tp.priority_id, tp.user_id) AS priority_id,
    upe.path AS priority_path,
    a.draft,
    ARRAY[]::uuid[] AS contacts,
    '{}'::jsonb AS contact_meta,
    ARRAY[]::uuid[] AS groups,
    NULL::bigint AS team_id,
    NULL::text AS topic,
    NULL::uuid AS topic_id,
    NULL::text AS title,
    NULL::text AS preview,
    NULL::text AS icon,
    NULL::uuid AS merged_into_thread_id,
    false AS has_embedding,
    NULL::uuid AS mute_by_thread_id,
    NULL::timestamp with time zone AS last_note_created_at,
    NULL::timestamp with time zone AS last_note_source_created_at,
    NULL::timestamp with time zone AS bumped_at,
    false AS unread,
    0::smallint AS importance,
    false AS active,
    NULL::boolean AS urgent,
    NULL::double precision AS state_order,
    NULL::daterange AS state_on,
    NULL::tstzrange AS state_at,
    a.created_at AS activity_at,
    tstzrange(a.created_at, a.created_at, '[]'::text) AS agenda_at,
    true AS revoked
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id)
  WHERE tp.revoked_at IS NOT NULL;
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
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
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.created_by = ua.user_id OR n.access_contacts IS NULL AND n.access_groups IS NULL OR n.access_contacts IS NOT NULL AND n.access_contacts && "user".user_contact_ids(ua.user_id) OR n.access_groups IS NOT NULL AND n.access_groups && "user".user_group_ids(ua.user_id));
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
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "seq",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    tt.occurrence,
    tt.updated_at,
    tt.seq,
    ua.priority_id,
    ua.priority_path,
    tt.tags
   FROM "user".thread ua
     JOIN LATERAL ( SELECT sq.occurrence,
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT at.occurrence,
                    at.tag_id,
                    jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
                    max(at.seq) AS seq
                   FROM public.thread_tag at
                  WHERE at.thread_id = ua.id
                  GROUP BY at.occurrence, at.tag_id) sq
          GROUP BY sq.occurrence) tt ON true;
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
