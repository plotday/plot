-- Drop "link" view
DROP VIEW "user"."link";
-- Drop "link_redacted" view
DROP VIEW "user"."link_redacted";
-- Modify "link" table
ALTER TABLE "public"."link" ADD COLUMN "priority" integer NOT NULL DEFAULT 0, ADD COLUMN "note_scoped" boolean NOT NULL DEFAULT false;
-- Create "link" view
CREATE VIEW "user"."link" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
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
  "priority",
  "note_scoped",
  "actions",
  "meta",
  "source_url",
  "channel_id",
  "logo",
  "priority_id",
  "merged_from_thread_id",
  "priority_path",
  "revoked"
) AS SELECT COALESCE(tp.user_id, p.user_id) AS user_id,
    l.id,
    l.created_at,
    l.updated_at,
    l.seq,
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
    l.priority,
    l.note_scoped,
    l.actions,
    l.meta,
    l.source_url,
    l.channel_id,
    l.logo,
    COALESCE("user".effective_priority_id(tp.priority_id, tp.user_id), l.priority_id) AS priority_id,
    l.merged_from_thread_id,
    COALESCE(upe.path, pp.path) AS priority_path,
    false AS revoked
   FROM public.link l
     LEFT JOIN public.twist_instance ti ON ti.id = l.created_by AND l.twist_id IS NOT NULL AND ti.archived_at IS NULL
     LEFT JOIN public.thread_priority tp ON tp.thread_id = l.thread_id AND tp.revoked_at IS NULL AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (l.twist_id IS NULL OR ti.owner_id = tp.user_id)
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, tp.user_id)
     LEFT JOIN public.priority pp ON pp.id = l.priority_id AND l.thread_id IS NULL
     LEFT JOIN public.priority p ON p.id = l.priority_id AND l.thread_id IS NULL
  WHERE l.archived_at IS NULL AND (tp.user_id IS NOT NULL OR p.user_id IS NOT NULL);
-- Create "link_redacted" view
CREATE VIEW "user"."link_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
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
  "priority",
  "note_scoped",
  "actions",
  "meta",
  "source_url",
  "channel_id",
  "logo",
  "priority_id",
  "merged_from_thread_id",
  "priority_path",
  "revoked"
) AS SELECT ti.owner_id AS user_id,
    l.id,
    l.created_at,
    l.archived_at AS updated_at,
    l.seq,
    l.thread_id,
    NULL::text AS source,
    l.source_created_at,
    NULL::uuid AS author_id,
    l.twist_id,
    l.created_by,
    l.updated_by,
    l.sync_depth,
    NULL::text AS title,
    NULL::text AS preview,
    NULL::uuid AS assignee_id,
    NULL::text AS type,
    NULL::text AS status,
    l.priority,
    l.note_scoped,
    NULL::jsonb AS actions,
    NULL::jsonb AS meta,
    NULL::text AS source_url,
    NULL::text AS channel_id,
    NULL::text AS logo,
    "user".effective_priority_id(tp.priority_id, ti.owner_id) AS priority_id,
    NULL::uuid AS merged_from_thread_id,
    upe.path AS priority_path,
    true AS revoked
   FROM public.link l
     JOIN public.twist_instance ti ON ti.id = l.created_by AND l.twist_id IS NOT NULL AND ti.archived_at IS NULL
     LEFT JOIN public.thread_priority tp ON tp.thread_id = l.thread_id AND tp.user_id = ti.owner_id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = ti.owner_id AND upe.priority_id = "user".effective_priority_id(tp.priority_id, ti.owner_id)
  WHERE l.archived_at IS NOT NULL;

-- Re-emit existing links so clients pick up the new priority / note_scoped columns.
UPDATE link SET updated_at = now();
