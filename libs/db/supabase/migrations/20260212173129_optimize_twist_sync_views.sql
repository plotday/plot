SET ROLE "postgres";
CREATE OR REPLACE VIEW public.priority_twist_activity_create WITH (security_invoker=true) AS SELECT pt.id AS priority_twist_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.source,
    a.meta,
    public.get_activity_mentions(a.id) AS mentions,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title,
    at.tags
   FROM (((((public.priority_twist pt
     JOIN public.priority pp ON ((pp.id = pt.priority_id)))
     JOIN public.priority pc ON ((pc.path OPERATOR(public.<@) pp.path)))
     JOIN public.activity a ON ((a.priority_id = pc.id)))
     LEFT JOIN public.actor author ON ((author.id = a.author_id)))
     LEFT JOIN public.activity_tags at ON (((at.activity_id = a.id) AND (at.occurrence IS NULL))))
  WHERE ((a.draft = false) AND (pt.id <> a.created_by) AND (a.archived_at IS NULL) AND (pt.archived_at IS NULL) AND (a.created_at > pt.created_at))
  ORDER BY a.created_at;
CREATE OR REPLACE VIEW public.priority_twist_activity_update WITH (security_invoker=true) AS SELECT a.created_by AS priority_twist_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.created_by,
    a.assignee_id,
    a.updated_by,
    a.sync_depth,
    a.archived_at,
    a.priority_id,
    a.type,
    a."order",
    a.draft,
    a.private,
    a.title,
    a.preview,
    a.at,
    a."on",
    a.duration,
    a.done_at,
    a.recurrence_rule,
    a.recurrence_exdates,
    a.source,
    a.meta,
    public.get_activity_mentions(a.id) AS mentions,
    author.name AS author_name,
    author.type AS author_type,
    pc.title AS priority_title,
    at.tags
   FROM (((((public.priority_twist pt
     JOIN public.priority pp ON ((pp.id = pt.priority_id)))
     JOIN public.priority pc ON ((pc.path OPERATOR(public.<@) pp.path)))
     JOIN public.activity a ON ((a.priority_id = pc.id)))
     LEFT JOIN public.actor author ON ((author.id = a.author_id)))
     LEFT JOIN public.activity_tags at ON (((at.activity_id = a.id) AND (at.occurrence IS NULL))))
  WHERE ((a.draft = false) AND (pt.id = a.created_by) AND (GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > a.created_at) AND (public.updated_by_uuid(pt.id) <> (a.updated_by)::numeric) AND (pt.archived_at IS NULL) AND (GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) > pt.created_at))
  ORDER BY GREATEST(a.updated_at, COALESCE(at.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone));
CREATE OR REPLACE VIEW public.priority_twist_note_create WITH (security_invoker=true) AS SELECT pt.id AS priority_twist_id,
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
    public.get_activity_mentions(a.id) AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags,
    fm.first_mentioned_at
   FROM (((((((public.priority_twist pt
     JOIN public.priority pp ON ((pp.id = pt.priority_id)))
     JOIN public.priority pc ON ((pc.path OPERATOR(public.<@) pp.path)))
     JOIN public.activity a ON ((a.priority_id = pc.id)))
     JOIN public.note n ON ((n.activity_id = a.id)))
     LEFT JOIN public.actor author ON ((author.id = n.author_id)))
     LEFT JOIN public.note_tags nt ON ((nt.note_id = n.id)))
     LEFT JOIN LATERAL ( SELECT min(note.created_at) AS first_mentioned_at
           FROM public.note
          WHERE ((note.activity_id = a.id) AND (pt.id = ANY (note.mentions)) AND (note.archived_at IS NULL))) fm ON (true))
  WHERE ((n.draft = false) AND (public.updated_by_uuid(pt.id) <> (n.updated_by)::numeric) AND (a.archived_at IS NULL) AND (pt.archived_at IS NULL) AND (n.created_at > pt.created_at) AND ((a.created_by = pt.id) OR ((fm.first_mentioned_at IS NOT NULL) AND (n.created_at >= fm.first_mentioned_at))))
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
    a.priority_id,
    a.title AS activity_title,
    a.created_by AS activity_created_by,
    a.meta AS activity_meta,
    public.get_activity_mentions(a.id) AS activity_mentions,
    author.name AS author_name,
    author.type AS author_type,
    nt.tags
   FROM ((((((public.priority_twist pt
     JOIN public.priority pp ON ((pp.id = pt.priority_id)))
     JOIN public.priority pc ON ((pc.path OPERATOR(public.<@) pp.path)))
     JOIN public.activity a ON ((a.priority_id = pc.id)))
     JOIN public.note n ON ((a.id = n.activity_id)))
     LEFT JOIN public.actor author ON ((author.id = n.author_id)))
     LEFT JOIN public.note_tags nt ON ((nt.note_id = n.id)))
  WHERE ((n.draft = false) AND (n.updated_at > n.created_at) AND (public.updated_by_uuid(pt.id) <> (n.updated_by)::numeric) AND (a.archived_at IS NULL) AND (pt.archived_at IS NULL) AND (n.updated_at > pt.created_at))
  ORDER BY n.updated_at;
