SET ROLE "postgres";
DROP VIEW public.user_activity_unread CASCADE;
COMMENT ON COLUMN public.activity.last_note_created_at IS 'Cached MAX(note.created_at) for non-draft, non-archived notes. Maintained by trigger. Used for unread status in user_activity and user_priority_unread views.';
CREATE INDEX idx_activity_updated_at ON public.activity (updated_at);
CREATE INDEX idx_note_updated_at ON public.note (updated_at);
CREATE OR REPLACE VIEW public.activity_x WITH (security_invoker=true) AS SELECT a.id,
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
    a.embedding,
    a.pick_priority,
    a.last_note_created_at,
    a.last_note_source_created_at,
    a.source_priority_root,
    p.path AS priority_path,
    m.mentions
   FROM ((public.activity a
     JOIN public.priority p ON ((p.id = a.priority_id)))
     LEFT JOIN LATERAL ( SELECT array_agg(DISTINCT mention.mention) AS mentions
           FROM public.note n,
            LATERAL unnest(n.mentions) mention(mention)
          WHERE ((n.activity_id = a.id) AND (n.archived_at IS NULL) AND (n.mentions IS NOT NULL))) m ON (true));
CREATE OR REPLACE VIEW public.user_activity WITH (security_invoker=true) AS SELECT upe.user_id,
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
     LEFT JOIN public.activity_read ar ON (((ar.user_id = upe.user_id) AND (ar.activity_id = a.id))));

-- Recreate views dropped by CASCADE on user_activity_unread
CREATE OR REPLACE VIEW public.user_activity_exception WITH (security_invoker=true) AS
SELECT
    ua.user_id,
    ae.id,
    ae.activity_id,
    COALESCE(ae.archived_at, ua.archived_at) AS archived_at,
    ae.occurrence,
    ae.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    ae.at,
    ae.on,
    ae.title,
    ae.preview
FROM
    activity_exception ae
    JOIN user_activity ua ON ua.id = ae.activity_id;

CREATE OR REPLACE VIEW public.user_activity_tags WITH (security_invoker=true) AS
SELECT
    ua.user_id,
    ua.id,
    ua.archived_at,
    at.occurrence,
    at.updated_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    at.tags
FROM
    activity_tags at
    JOIN user_activity ua ON ua.id = at.activity_id;

CREATE OR REPLACE VIEW public.user_note_tags WITH (security_invoker=true) AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_path,
    ua.range_at,
    ua.range_on,
    nt.tags
FROM
    note_tags nt
    JOIN note n ON n.id = nt.note_id
    JOIN user_activity ua ON ua.id = n.activity_id;

-- Recreate actor function dropped by CASCADE
CREATE OR REPLACE FUNCTION public.actor (user_activity)
    RETURNS SETOF actor
    LANGUAGE sql
    STABLE ROWS 1
    AS $function$
    SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$function$;

CREATE OR REPLACE TRIGGER set_activity_source_priority_root_trigger BEFORE INSERT OR UPDATE OF source, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.set_activity_source_priority_root();
CREATE OR REPLACE TRIGGER update_activity_last_note_created_at_on_status_change AFTER UPDATE OF draft, archived_at ON public.note FOR EACH ROW WHEN (old.draft IS DISTINCT FROM new.draft OR old.archived_at IS DISTINCT FROM new.archived_at) EXECUTE FUNCTION public.update_activity_on_note_change();

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_tag_change" SET ( security_invoker = TRUE);
ALTER VIEW public.priority_member SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
