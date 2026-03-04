-- Create "priority_twist_channel" table
CREATE TABLE "public"."priority_twist_channel" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "priority_twist_id" uuid NOT NULL,
  "source_priority_twist_id" uuid NOT NULL,
  "channel_id" text NOT NULL,
  "enabled" boolean NOT NULL DEFAULT true,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id"),
  CONSTRAINT "priority_twist_channel_priority_twist_id_source_priority_tw_key" UNIQUE ("priority_twist_id", "source_priority_twist_id", "channel_id"),
  CONSTRAINT "priority_twist_channel_priority_twist_id_fkey" FOREIGN KEY ("priority_twist_id") REFERENCES "public"."priority_twist" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "priority_twist_channel_source_priority_twist_id_fkey" FOREIGN KEY ("source_priority_twist_id") REFERENCES "public"."priority_twist" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_ptc_priority_twist_id" to table: "priority_twist_channel"
CREATE INDEX "idx_ptc_priority_twist_id" ON "public"."priority_twist_channel" ("priority_twist_id");
-- Create index "idx_ptc_source" to table: "priority_twist_channel"
CREATE INDEX "idx_ptc_source" ON "public"."priority_twist_channel" ("source_priority_twist_id", "channel_id");
-- Create "priority_twist_channel_link_create" view
CREATE VIEW "public"."priority_twist_channel_link_create" (
  "priority_twist_id",
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
  "channel_id",
  "source_url",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT ptc.priority_twist_id,
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
    l.channel_id,
    l.source_url,
    t.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.priority_twist_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_priority_twist_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.priority_twist pt ON pt.id = ptc.priority_twist_id
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.id = t.priority_id AND pc.path OPERATOR(public.<@) pp.path
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND l.created_at > pt.created_at
  ORDER BY l.created_at;
-- Create "priority_twist_channel_link_update" view
CREATE VIEW "public"."priority_twist_channel_link_update" (
  "priority_twist_id",
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
  "channel_id",
  "source_url",
  "priority_id",
  "author_name",
  "author_type",
  "priority_title"
) AS SELECT ptc.priority_twist_id,
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
    l.channel_id,
    l.source_url,
    t.priority_id,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title
   FROM public.priority_twist_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_priority_twist_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.priority_twist pt ON pt.id = ptc.priority_twist_id
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.id = t.priority_id AND pc.path OPERATOR(public.<@) pp.path
     LEFT JOIN public.actor author ON author.id = l.author_id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND l.updated_at > l.created_at AND public.updated_by_uuid(ptc.priority_twist_id) <> l.updated_by::numeric AND l.updated_at > pt.created_at
  ORDER BY l.updated_at;
-- Create "priority_twist_channel_note_create" view
CREATE VIEW "public"."priority_twist_channel_note_create" (
  "priority_twist_id",
  "id",
  "created_at",
  "updated_at",
  "source_created_at",
  "author_id",
  "created_by",
  "updated_by",
  "sync_depth",
  "archived_at",
  "thread_id",
  "draft",
  "private",
  "content",
  "actions",
  "key",
  "mentions",
  "re_note_id",
  "link_id",
  "link_source",
  "link_title",
  "link_type",
  "link_meta",
  "link_channel_id",
  "link_source_url",
  "priority_id",
  "thread_title",
  "thread_created_by",
  "author_name",
  "author_type",
  "tags"
) AS SELECT DISTINCT ON (ptc.priority_twist_id, n.id) ptc.priority_twist_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.private,
    n.content,
    n.actions,
    n.key,
    n.mentions,
    n.re_note_id,
    l.id AS link_id,
    l.source AS link_source,
    l.title AS link_title,
    l.type AS link_type,
    l.meta AS link_meta,
    l.channel_id AS link_channel_id,
    l.source_url AS link_source_url,
    t.priority_id,
    t.title AS thread_title,
    t.created_by AS thread_created_by,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.priority_twist_channel ptc
     JOIN public.link l ON l.created_by = ptc.source_priority_twist_id AND l.channel_id = ptc.channel_id
     JOIN public.thread t ON t.id = l.thread_id
     JOIN public.note n ON n.thread_id = t.id
     JOIN public.priority_twist pt ON pt.id = ptc.priority_twist_id
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.id = t.priority_id AND pc.path OPERATOR(public.<@) pp.path
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE ptc.enabled = true AND pt.archived_at IS NULL AND t.draft = false AND n.draft = false AND n.created_by <> ptc.priority_twist_id AND n.created_at > pt.created_at
  ORDER BY ptc.priority_twist_id, n.id, n.created_at;
-- Drop "priority_twist_thread_create" view
DROP VIEW "public"."priority_twist_thread_create";
