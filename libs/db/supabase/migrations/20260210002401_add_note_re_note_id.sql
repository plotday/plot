SET ROLE "postgres";
ALTER TABLE public.note ADD COLUMN re_note_id uuid;
ALTER TABLE public.note ADD CONSTRAINT note_re_note_id_fkey FOREIGN KEY (re_note_id) REFERENCES public.note(id) ON DELETE SET NULL;
CREATE INDEX idx_note_re_note_id ON public.note (re_note_id) WHERE re_note_id IS NOT NULL;
DROP VIEW IF EXISTS public.priority_twist_note_create;
DROP VIEW IF EXISTS public.priority_twist_note_update;
DROP VIEW IF EXISTS public.user_note;
CREATE OR REPLACE VIEW public.priority_twist_note_create WITH (security_invoker=true) AS SELECT pct.id AS priority_twist_id,
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
    ax.priority_id,
    ax.title AS activity_title,
    ax.created_by AS activity_created_by,
    ax.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags,
    fm.first_mentioned_at
   FROM (((((public.priority_child_twist pct
     JOIN public.activity_x ax ON ((ax.priority_id = pct.priority_child_id)))
     JOIN public.note n ON ((n.activity_id = ax.id)))
     LEFT JOIN public.actor author ON ((author.id = n.author_id)))
     LEFT JOIN public.note_tags nt ON ((nt.note_id = n.id)))
     LEFT JOIN LATERAL ( SELECT min(note.created_at) AS first_mentioned_at
           FROM public.note
          WHERE ((note.activity_id = ax.id) AND (pct.id = ANY (note.mentions)) AND (note.archived_at IS NULL))) fm ON (true))
  WHERE ((n.draft = false) AND (public.updated_by_uuid(pct.id) <> (n.updated_by)::numeric) AND (ax.archived_at IS NULL) AND (pct.archived_at IS NULL) AND (n.created_at > pct.created_at) AND ((ax.created_by = pct.id) OR ((fm.first_mentioned_at IS NOT NULL) AND (n.created_at >= fm.first_mentioned_at))))
  ORDER BY n.created_at;
CREATE OR REPLACE VIEW public.priority_twist_note_update WITH (security_invoker=true) AS SELECT n.created_by AS priority_twist_id,
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
    ax.priority_id,
    ax.title AS activity_title,
    ax.created_by AS activity_created_by,
    ax.meta AS activity_meta,
    ax.mentions AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM ((((public.priority_child_twist pct
     JOIN public.activity_x ax ON ((ax.priority_id = pct.priority_child_id)))
     JOIN public.note n ON ((ax.id = n.activity_id)))
     LEFT JOIN public.actor author ON ((author.id = n.author_id)))
     LEFT JOIN public.note_tags nt ON ((nt.note_id = n.id)))
  WHERE ((n.draft = false) AND (n.updated_at > n.created_at) AND (public.updated_by_uuid(pct.id) <> (n.updated_by)::numeric) AND (ax.archived_at IS NULL) AND (pct.archived_at IS NULL) AND (n.updated_at > pct.created_at))
  ORDER BY n.updated_at;
CREATE OR REPLACE VIEW public.user_note AS SELECT upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.activity_id,
    n.draft,
    n.private,
    n.content,
    n.links,
    n.mentions,
    n.re_note_id
   FROM ((public.note n
     JOIN public.activity a ON ((a.id = n.activity_id)))
     JOIN public.user_priority_expanded upe ON ((upe.priority_id = a.priority_id)))
  WHERE (((auth.uid() IS NULL) OR (upe.user_id = auth.uid())) AND ((n.draft = false) OR (auth.uid() IS NULL) OR (n.created_by = auth.uid())) AND ((n.private = false) OR (auth.uid() IS NULL) OR (n.created_by = auth.uid()) OR (auth.uid() = ANY (n.mentions))) AND ((a.draft = false) OR (auth.uid() IS NULL) OR (a.created_by = auth.uid())) AND
        CASE
            WHEN (a.private = false) THEN true
            WHEN (auth.uid() IS NULL) THEN true
            WHEN (a.created_by = auth.uid()) THEN true
            ELSE public.user_mentioned_in_activity(auth.uid(), a.id)
        END)
UNION ALL
 SELECT upe.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.activity_id,
    n.draft,
    n.private,
    NULL::text AS content,
    NULL::jsonb AS links,
    NULL::uuid[] AS mentions,
    n.re_note_id
   FROM ((public.note n
     JOIN public.activity a ON ((a.id = n.activity_id)))
     JOIN public.user_priority_expanded upe ON ((upe.priority_id = a.priority_id)))
  WHERE ((auth.uid() IS NOT NULL) AND (upe.user_id = auth.uid()) AND ((n.draft = false) OR (n.created_by = auth.uid())) AND ((a.draft = false) OR (a.created_by = auth.uid())) AND (((n.private = true) AND (n.created_by <> auth.uid()) AND (NOT (auth.uid() = ANY (COALESCE(n.mentions, '{}'::uuid[]))))) OR ((a.private = true) AND (a.created_by <> auth.uid()) AND (NOT public.user_mentioned_in_activity(auth.uid(), a.id)))));
ALTER VIEW "public"."user_note" OWNER TO postgres;
REVOKE SELECT ON "public"."user_note" FROM anon;
