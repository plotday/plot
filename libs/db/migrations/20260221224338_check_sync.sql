-- Create index "idx_activity_created_by" to table: "activity"
CREATE INDEX "idx_activity_created_by" ON "public"."activity" ("created_by") WHERE (archived_at IS NULL);
-- Modify "priority_twist_note_create" view
CREATE OR REPLACE VIEW "public"."priority_twist_note_create" (
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
) AS SELECT base.priority_twist_id,
    base.id,
    base.created_at,
    base.updated_at,
    base.source_created_at,
    base.author_id,
    base.created_by,
    base.updated_by,
    base.sync_depth,
    base.archived_at,
    base.activity_id,
    base.draft,
    base.private,
    base.content,
    base.links,
    base.key,
    base.mentions,
    base.re_note_id,
    base.priority_id,
    base.activity_title,
    base.activity_created_by,
    base.activity_meta,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM ( SELECT pt.id AS priority_twist_id,
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
            a.meta AS activity_meta
           FROM public.priority_twist pt
             JOIN public.priority pp ON pp.id = pt.priority_id
             JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
             JOIN public.activity a ON a.priority_id = pc.id AND a.created_by = pt.id AND a.archived_at IS NULL
             JOIN public.note n ON n.activity_id = a.id
          WHERE n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at
        UNION ALL
         SELECT pt.id AS priority_twist_id,
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
            a.meta AS activity_meta
           FROM public.priority_twist pt
             JOIN public.priority pp ON pp.id = pt.priority_id
             JOIN public.priority pc ON pc.path OPERATOR(public.<@) pp.path
             JOIN public.activity a ON a.priority_id = pc.id AND a.created_by <> pt.id AND a.archived_at IS NULL
             JOIN LATERAL ( SELECT min(m.created_at) AS first_mention_at
                   FROM public.note m
                  WHERE m.activity_id = a.id AND (pt.id = ANY (m.mentions)) AND m.archived_at IS NULL) fm ON fm.first_mention_at IS NOT NULL
             JOIN public.note n ON n.activity_id = a.id AND n.created_at >= fm.first_mention_at
          WHERE n.draft = false AND n.created_by <> pt.id AND public.updated_by_uuid(pt.id) <> n.updated_by::numeric AND pt.archived_at IS NULL AND n.created_at > pt.created_at) base
     LEFT JOIN public.actor author ON author.id = base.author_id
     LEFT JOIN public.note_tags nt ON nt.note_id = base.id
  ORDER BY base.created_at;
