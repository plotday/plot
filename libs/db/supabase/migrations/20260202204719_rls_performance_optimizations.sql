SET ROLE "postgres";
SET check_function_bodies = false;
ALTER FUNCTION public.can_access_priority(uuid) STABLE;
ALTER FUNCTION public.can_access_priority(ltree) STABLE;
CREATE FUNCTION public.get_activity_mentions(p_activity_id uuid)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
    SELECT
        ARRAY_AGG(DISTINCT mention)
    FROM
        note n,
        LATERAL unnest(n.mentions) AS mention
    WHERE
        n.activity_id = p_activity_id
        AND n.archived_at IS NULL
        AND n.mentions IS NOT NULL;
$function$;
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
    public.get_activity_mentions(a.id) AS mentions
   FROM (public.activity a
     JOIN public.priority p ON ((p.id = a.priority_id)));
CREATE OR REPLACE TRIGGER set_activity_source_priority_root_trigger BEFORE INSERT OR UPDATE OF source, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.set_activity_source_priority_root();
CREATE OR REPLACE TRIGGER update_activity_last_note_created_at_on_status_change AFTER UPDATE OF draft, archived_at ON public.note FOR EACH ROW WHEN (old.draft IS DISTINCT FROM new.draft OR old.archived_at IS DISTINCT FROM new.archived_at) EXECUTE FUNCTION public.update_activity_on_note_change();
ALTER POLICY "Users can update activities in their accessible priorities" ON public.activity USING ((public.user_has_priority_access(( SELECT auth.uid() AS uid), priority_id) AND ((draft = false) OR (created_by = ( SELECT auth.uid() AS uid))) AND
CASE
    WHEN (private = false) THEN true
    WHEN (created_by = ( SELECT auth.uid() AS uid)) THEN true
    ELSE public.user_mentioned_in_activity(( SELECT auth.uid() AS uid), id)
END));
ALTER POLICY "Users can update activities in their accessible priorities" ON public.activity WITH CHECK ((public.user_has_priority_access(( SELECT auth.uid() AS uid), priority_id) AND ((draft = false) OR (created_by = ( SELECT auth.uid() AS uid))) AND
CASE
    WHEN (private = false) THEN true
    WHEN (created_by = ( SELECT auth.uid() AS uid)) THEN true
    ELSE public.user_mentioned_in_activity(( SELECT auth.uid() AS uid), id)
END));
ALTER POLICY "Users can view activities in their accessible priorities" ON public.activity USING ((public.user_has_priority_access(( SELECT auth.uid() AS uid), priority_id) AND ((draft = false) OR (created_by = ( SELECT auth.uid() AS uid))) AND
CASE
    WHEN (private = false) THEN true
    WHEN (created_by = ( SELECT auth.uid() AS uid)) THEN true
    ELSE public.user_mentioned_in_activity(( SELECT auth.uid() AS uid), id)
END));

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
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
