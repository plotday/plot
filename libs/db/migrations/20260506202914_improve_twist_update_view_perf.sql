-- Create index "idx_note_created_by_seq" to table: "note"
CREATE INDEX "idx_note_created_by_seq" ON "public"."note" ("created_by", "seq");
-- Create index "idx_thread_created_by_seq" to table: "thread"
CREATE INDEX "idx_thread_created_by_seq" ON "public"."thread" ("created_by", "seq");
-- Modify "twist_instance_note_update" view
CREATE OR REPLACE VIEW "public"."twist_instance_note_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "thread_id",
  "draft",
  "access_contacts",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "thread_meta",
  "author_name",
  "author_type",
  "tags"
) AS SELECT n.created_by AS twist_instance_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.seq,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    tp.priority_id,
    a.title AS thread_title,
    a.created_by AS thread_created_by,
    NULL::jsonb AS thread_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.twist_instance pt
     JOIN public.note n ON n.created_by = pt.id
     JOIN public.thread a ON a.id = n.thread_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.updated_at > n.created_at AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND a.archived_at IS NULL AND pt.archived_at IS NULL AND n.updated_at > pt.created_at;
-- Modify "twist_instance_thread_update" view
CREATE OR REPLACE VIEW "public"."twist_instance_thread_update" (
  "twist_instance_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "priority_id",
  "draft",
  "contacts",
  "title",
  "preview",
  "priority_title",
  "tags"
) AS SELECT a.created_by AS twist_instance_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.seq,
    a.created_by,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    tp.priority_id,
    a.draft,
    a.contacts,
    a.title,
    a.preview,
    pc.title AS priority_title,
    at.tags
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.priority pc ON pc.id = tp.priority_id
     LEFT JOIN public.thread_tags at ON at.thread_id = a.id AND at.occurrence IS NULL
  WHERE a.draft = false AND a.updated_at > a.created_at AND public.updated_by_uuid(pt.id) <> a.updated_by::numeric AND pt.archived_at IS NULL AND a.updated_at > pt.created_at
UNION ALL
 SELECT a.created_by AS twist_instance_id,
    a.id,
    a.created_at,
    COALESCE(tt.archived_at, tt.updated_at) AS updated_at,
    tt.seq,
    a.created_by,
    tt.updated_by,
    a.sync_depth,
    a.archived_at,
    tp.priority_id,
    a.draft,
    a.contacts,
    a.title,
    a.preview,
    pc.title AS priority_title,
    at.tags
   FROM public.thread_tag tt
     JOIN public.thread a ON a.id = tt.thread_id
     JOIN public.twist_instance pt ON pt.id = a.created_by
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
     LEFT JOIN public.priority pc ON pc.id = tp.priority_id
     LEFT JOIN public.thread_tags at ON at.thread_id = a.id AND at.occurrence IS NULL
  WHERE tt.occurrence IS NULL AND a.draft = false AND COALESCE(tt.archived_at, tt.updated_at) > a.created_at AND public.updated_by_uuid(pt.id) <> tt.updated_by::numeric AND pt.archived_at IS NULL AND COALESCE(tt.archived_at, tt.updated_at) > pt.created_at;
