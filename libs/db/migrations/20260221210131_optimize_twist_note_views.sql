-- Drop "priority_twist_note_create" view
DROP VIEW "public"."priority_twist_note_create";
-- Create "priority_twist_note_create" view
CREATE VIEW "public"."priority_twist_note_create" (
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
  "activity_id",
  "draft",
  "private",
  "content",
  "links",
  "key",
  "mentions",
  "re_note_id",
  "priority_id",
  "activity_title",
  "activity_created_by",
  "activity_meta",
  "author_name",
  "author_type",
  "tags"
) AS SELECT pt.id AS priority_twist_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.key,
    n.mentions,
    n.re_note_id,
    a.priority_id,
    a.title AS activity_title,
    a.created_by AS activity_created_by,
    a.meta AS activity_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.activity a ON a.priority_id = pc.id
     JOIN public.note n ON n.activity_id = a.id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND a.archived_at IS NULL AND pt.archived_at IS NULL AND n.created_at > pt.created_at AND (a.created_by = pt.id OR (EXISTS ( SELECT 1
           FROM public.note m
          WHERE m.activity_id = a.id AND (pt.id = ANY (m.mentions)) AND m.archived_at IS NULL AND m.created_at <= n.created_at)))
  ORDER BY n.created_at;
-- Drop "priority_twist_note_update" view
DROP VIEW "public"."priority_twist_note_update";
-- Create "priority_twist_note_update" view
CREATE VIEW "public"."priority_twist_note_update" (
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
  "activity_id",
  "draft",
  "private",
  "content",
  "links",
  "key",
  "mentions",
  "re_note_id",
  "priority_id",
  "activity_title",
  "activity_created_by",
  "activity_meta",
  "author_name",
  "author_type",
  "tags"
) AS SELECT n.created_by AS priority_twist_id,
    n.id,
    n.created_at,
    GREATEST(n.updated_at, COALESCE(nt.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.sync_depth,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.key,
    n.mentions,
    n.re_note_id,
    a.priority_id,
    a.title AS activity_title,
    a.created_by AS activity_created_by,
    a.meta AS activity_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM public.priority_twist pt
     JOIN public.priority pp ON pp.id = pt.priority_id
     JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
     JOIN public.activity a ON a.priority_id = pc.id
     JOIN public.note n ON a.id = n.activity_id
     LEFT JOIN public.actor author ON author.id = n.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = n.id
  WHERE n.draft = false AND n.updated_at > n.created_at AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND a.archived_at IS NULL AND pt.archived_at IS NULL AND n.updated_at > pt.created_at
  ORDER BY n.updated_at;
