SET ROLE "postgres";
SET check_function_bodies = false;
CREATE OR REPLACE FUNCTION public.all_views_secure()
 RETURNS boolean
 LANGUAGE plpgsql
AS $function$
DECLARE
    VIEW text;
BEGIN
    SELECT
        relname INTO VIEW
    FROM
        pg_class
        JOIN pg_catalog.pg_namespace n ON n.oid = pg_class.relnamespace
    WHERE
        n.nspname = 'public'
        AND relname NOT LIKE '%_admin'
        AND relname NOT IN (
            'user_activity',
            'user_note',
            'user_activity_exception',
            'user_activity_tags',
            'user_note_tags'
        )
        AND relkind = 'v'
        AND (lower(reloptions::text)::text[] && ARRAY['security_invoker=1', 'security_invoker=true', 'security_invoker=on']) IS NULL;
    IF FOUND THEN
        RAISE EXCEPTION 'Found view without security_invoker: %', VIEW;
    END IF;
    RETURN TRUE;
END
$function$;
CREATE OR REPLACE VIEW public.user_activity AS SELECT upe.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone),
        CASE
            WHEN ((a.archived_at IS NULL) AND (((a.created_by = upe.user_id) AND (a.last_note_created_at IS NOT NULL) AND (a.last_note_created_at > upe.joined_at)) OR (((a.created_by IS NULL) OR (a.created_by <> upe.user_id)) AND (COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at)))) THEN GREATEST(COALESCE(
            CASE
                WHEN (ar.read_at >=
                CASE
                    WHEN (a.created_by = upe.user_id) THEN a.last_note_created_at
                    ELSE COALESCE(a.last_note_created_at, a.created_at)
                END) THEN ar.updated_at
                ELSE NULL::timestamp with time zone
            END, '1970-01-01 00:00:00+00'::timestamp with time zone),
            CASE
                WHEN (a.created_by = upe.user_id) THEN COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)
                ELSE COALESCE(a.last_note_created_at, a.created_at)
            END)
            ELSE '1970-01-01 00:00:00+00'::timestamp with time zone
        END) AS updated_at,
    a.source_created_at,
    a.author_id,
    a.assignee_id,
    a.updated_by,
    COALESCE(a.archived_at, upe.archived_at) AS archived_at,
    a.priority_id,
    a.priority_path,
    a.type,
    a.kind,
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
    a.meta,
    a.source,
    a.created_by_twist_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.mentions,
        CASE
            WHEN (a.done_at IS NOT NULL) THEN tstzrange(a.done_at, a.done_at, '[]'::text)
            WHEN (((a.assignee_id IS NOT NULL) AND (( SELECT c.user_id
               FROM public.contact c
              WHERE (c.id = a.assignee_id)) <> upe.user_id)) OR (a."on" IS NULL)) THEN
            CASE
                WHEN (lower(a.at) >= GREATEST(a.source_created_at, COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone))) THEN a.at
                ELSE tstzrange(GREATEST(a.source_created_at, COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)), GREATEST(a.source_created_at, COALESCE(a.last_note_source_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone)), '[]'::text)
            END
            ELSE NULL::tstzrange
        END AS range_at,
        CASE
            WHEN (a.done_at IS NOT NULL) THEN NULL::daterange
            WHEN ((a.assignee_id IS NOT NULL) AND (( SELECT c.user_id
               FROM public.contact c
              WHERE (c.id = a.assignee_id)) <> upe.user_id)) THEN NULL::daterange
            WHEN (a.at IS NOT NULL) THEN NULL::daterange
            WHEN (a."on" IS NOT NULL) THEN a."on"
            ELSE NULL::daterange
        END AS range_on,
    COALESCE(
        CASE
            WHEN ((a.archived_at IS NULL) AND (((a.created_by = upe.user_id) AND (a.last_note_created_at IS NOT NULL) AND (a.last_note_created_at > upe.joined_at)) OR (((a.created_by IS NULL) OR (a.created_by <> upe.user_id)) AND (COALESCE(a.last_note_created_at, a.created_at) > upe.joined_at)))) THEN ((ar.read_at IS NULL) OR (ar.read_at <
            CASE
                WHEN (a.created_by = upe.user_id) THEN a.last_note_created_at
                ELSE COALESCE(a.last_note_created_at, a.created_at)
            END))
            ELSE false
        END, false) AS unread
   FROM ((public.activity_x a
     JOIN public.user_priority_expanded upe ON ((a.priority_id = upe.priority_id)))
     LEFT JOIN public.activity_read ar ON (((ar.user_id = upe.user_id) AND (ar.activity_id = a.id))))
  WHERE (((auth.uid() IS NULL) OR (upe.user_id = auth.uid())) AND ((a.draft = false) OR (auth.uid() IS NULL) OR (a.created_by = auth.uid())) AND
        CASE
            WHEN (a.private = false) THEN true
            WHEN (auth.uid() IS NULL) THEN true
            WHEN (a.created_by = auth.uid()) THEN true
            ELSE public.user_mentioned_in_activity(auth.uid(), a.id)
        END);
ALTER VIEW public.user_activity_exception RESET (security_invoker);
REVOKE SELECT ON public.user_activity_exception FROM anon;
ALTER VIEW public.user_activity_tags RESET (security_invoker);
REVOKE SELECT ON public.user_activity_tags FROM anon;
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
    n.mentions
   FROM ((public.note n
     JOIN public.activity a ON ((a.id = n.activity_id)))
     JOIN public.user_priority_expanded upe ON ((upe.priority_id = a.priority_id)))
  WHERE (((auth.uid() IS NULL) OR (upe.user_id = auth.uid())) AND ((n.draft = false) OR (auth.uid() IS NULL) OR (n.created_by = auth.uid())) AND ((n.private = false) OR (auth.uid() IS NULL) OR (n.created_by = auth.uid()) OR (auth.uid() = ANY (n.mentions))) AND ((a.draft = false) OR (auth.uid() IS NULL) OR (a.created_by = auth.uid())) AND
        CASE
            WHEN (a.private = false) THEN true
            WHEN (auth.uid() IS NULL) THEN true
            WHEN (a.created_by = auth.uid()) THEN true
            ELSE public.user_mentioned_in_activity(auth.uid(), a.id)
        END);
CREATE OR REPLACE VIEW public.user_note_tags AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
   FROM ((public.note_tags nt
     JOIN public.note n ON ((n.id = nt.note_id)))
     JOIN public.user_activity ua ON ((ua.id = n.activity_id)))
  WHERE (((n.draft = false) OR (auth.uid() IS NULL) OR (n.created_by = auth.uid())) AND ((n.private = false) OR (auth.uid() IS NULL) OR (n.created_by = auth.uid()) OR (auth.uid() = ANY (n.mentions))));
-- Set owner and revoke anon access for security definer views
ALTER VIEW public.user_activity OWNER TO postgres;
REVOKE SELECT ON public.user_activity FROM anon;
ALTER VIEW public.user_activity_exception OWNER TO postgres;
REVOKE SELECT ON public.user_activity_exception FROM anon;
ALTER VIEW public.user_activity_tags OWNER TO postgres;
REVOKE SELECT ON public.user_activity_tags FROM anon;
ALTER VIEW public.user_note OWNER TO postgres;
REVOKE SELECT ON public.user_note FROM anon;
ALTER VIEW public.user_note_tags OWNER TO postgres;
REVOKE SELECT ON public.user_note_tags FROM anon;
