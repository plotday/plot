DROP POLICY "Users can update activities in their accessible priorities" ON "public"."activity";

DROP POLICY "Users can view activities in their accessible priorities" ON "public"."activity";

DROP POLICY "Users can update notes for accessible activities" ON "public"."note";

DROP POLICY "Users can view notes for accessible activities" ON "public"."note";

CREATE UNIQUE INDEX idx_activity_unique_draft_per_user_priority ON public.activity USING btree (created_by, priority_id)
WHERE ((draft = TRUE) AND (archived_at IS NULL));

CREATE UNIQUE INDEX idx_note_unique_draft_per_user_activity ON public.note USING btree (created_by, activity_id)
WHERE ((draft = TRUE) AND (archived_at IS NULL));

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.user_mentioned_in_activity (user_id uuid, activity_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.note
            WHERE
                note.activity_id = user_mentioned_in_activity.activity_id
                AND note.archived_at IS NULL
                AND user_mentioned_in_activity.user_id = ANY (note.mentions));
$function$;

CREATE POLICY "Users can update activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR UPDATE TO public
        USING ((user_has_priority_access (auth.uid (), priority_id) AND ((draft = FALSE) OR (created_by = auth.uid ())) AND ((private = FALSE) OR (created_by = auth.uid ()) OR user_mentioned_in_activity (auth.uid (), id))))
        WITH CHECK ((user_has_priority_access (auth.uid (), priority_id) AND ((draft = FALSE) OR (created_by = auth.uid ())) AND ((private = FALSE) OR (created_by = auth.uid ()) OR user_mentioned_in_activity (auth.uid (), id))));

CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR SELECT TO public
        USING ((user_has_priority_access (auth.uid (), priority_id) AND ((draft = FALSE) OR (created_by = auth.uid ())) AND ((private = FALSE) OR (created_by = auth.uid ()) OR user_mentioned_in_activity (auth.uid (), id))));

CREATE POLICY "Users can update notes for accessible activities" ON "public"."note" AS permissive
    FOR UPDATE TO public
        USING (((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))) AND ((draft = FALSE) OR (created_by = auth.uid ())) AND ((private = FALSE) OR (created_by = auth.uid ()) OR (auth.uid () = ANY (mentions)))))
        WITH CHECK (((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))) AND ((draft = FALSE) OR (created_by = auth.uid ())) AND ((private = FALSE) OR (created_by = auth.uid ()) OR (auth.uid () = ANY (mentions)))));

CREATE POLICY "Users can view notes for accessible activities" ON "public"."note" AS permissive
    FOR SELECT TO public
        USING (((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))) AND ((draft = FALSE) OR (created_by = auth.uid ())) AND ((private = FALSE) OR (created_by = auth.uid ()) OR (auth.uid () = ANY (mentions)))));

ALTER VIEW "public"."user_note" SET (security_invoker = TRUE);

ALTER VIEW "public"."note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_note_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_twist" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_x" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority_base" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

