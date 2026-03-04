-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Modify "thread" view
CREATE OR REPLACE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "private",
  "title",
  "preview",
  "last_note_created_at",
  "last_note_source_created_at",
  "mentions",
  "unread",
  "activity_at",
  "agenda_at"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        ), user_done AS (
         SELECT schedule.thread_id,
            schedule.user_id,
            schedule.done_at
           FROM public.schedule
          WHERE schedule.link_id IS NULL AND schedule.occurrence IS NULL AND schedule.done_at IS NOT NULL
        )
 SELECT upe.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone),
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN GREATEST(COALESCE(
            CASE
                WHEN ar.read_at >=
                CASE
                    WHEN a.created_by = upe.user_id THEN a.last_note_source_created_at
                    ELSE COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ud.done_at), a.created_at)
                END THEN ar.updated_at
                ELSE NULL::timestamp with time zone
            END, '1970-01-01 00:00:00+00'::timestamp with time zone),
            CASE
                WHEN a.created_by = upe.user_id THEN COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
                ELSE COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ud.done_at), a.created_at)
            END)
            ELSE '1970-01-01 00:00:00+00'::timestamp with time zone
        END) AS updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
    COALESCE(
        CASE
            WHEN a.archived_at IS NULL AND (a.created_by = upe.user_id AND a.last_note_created_at IS NOT NULL AND a.last_note_created_at > upe.joined_at OR (a.created_by IS NULL OR a.created_by <> upe.user_id) AND COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at) THEN ar.read_at IS NULL OR ar.read_at <
            CASE
                WHEN a.created_by = upe.user_id THEN a.last_note_source_created_at
                ELSE COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ud.done_at), a.created_at)
            END
            ELSE false
        END, false) AS unread,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ud.done_at), a.created_at) AS activity_at,
    COALESCE(LEAST(( SELECT COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamp with time zone) AS "coalesce"
           FROM public.schedule s_agg
          WHERE s_agg.thread_id = a.id AND s_agg.user_id IS NULL AND s_agg.archived_at IS NULL
          ORDER BY (COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamp with time zone))
         LIMIT 1), ( SELECT COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamp with time zone) AS "coalesce"
           FROM public.schedule s_agg
          WHERE s_agg.thread_id = a.id AND s_agg.user_id = upe.user_id AND s_agg.archived_at IS NULL AND s_agg.done_at IS NULL
          ORDER BY (COALESCE(lower(s_agg.at), lower(s_agg."on")::timestamp with time zone))
         LIMIT 1)), a.created_at) AS agenda_at
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
     LEFT JOIN public.thread_read ar ON ar.user_id = upe.user_id AND ar.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
     LEFT JOIN user_done ud ON ud.thread_id = a.id AND ud.user_id = upe.user_id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND
        CASE
            WHEN a.private = false THEN true
            WHEN a.created_by = upe.user_id THEN true
            ELSE "user".mentioned_in_thread(upe.user_id, a.id)
        END
UNION ALL
 SELECT upe.user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at, a.updated_at) AS archived_at,
    a.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.private,
    NULL::text AS title,
    NULL::text AS preview,
    a.last_note_created_at,
    a.last_note_source_created_at,
    NULL::uuid[] AS mentions,
    false AS unread,
    a.created_at AS activity_at,
    a.created_at AS agenda_at
   FROM public.thread_x a
     JOIN "user".priority_expanded upe ON a.priority_id = upe.priority_id
  WHERE (a.draft = false OR a.created_by = upe.user_id) AND a.private = true AND a.created_by <> upe.user_id AND NOT "user".mentioned_in_thread(upe.user_id, a.id);
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM public.note_tags nt
     JOIN public.note n ON n.id = nt.note_id
     JOIN "user".thread ua ON ua.id = n.thread_id
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.private = false OR n.created_by = ua.user_id OR (ua.user_id = ANY (n.mentions)));
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    at.occurrence,
    at.updated_at,
    ua.priority_id,
    ua.priority_path,
    at.tags
   FROM public.thread_tags at
     JOIN "user".thread ua ON ua.id = at.thread_id;
-- Modify "link" view
CREATE OR REPLACE VIEW "user"."link" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "thread_id",
  "source",
  "source_created_at",
  "author_id",
  "twist_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "title",
  "preview",
  "assignee_id",
  "type",
  "status",
  "actions",
  "meta",
  "source_url",
  "priority_id",
  "priority_path"
) AS SELECT upe.user_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.thread_id,
    l.source,
    l.source_created_at,
    l.author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    l.title,
    l.preview,
    l.assignee_id,
    l.type,
    l.status,
    l.actions,
    l.meta,
    l.source_url,
    l.priority_id,
    upe.path AS priority_path
   FROM public.link_x l
     JOIN "user".priority_expanded upe ON l.priority_id = upe.priority_id;
