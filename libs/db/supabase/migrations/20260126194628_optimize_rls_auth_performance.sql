DROP POLICY "Users can insert activities in their accessible priorities" ON "public"."activity";

DROP POLICY "Users can update activities in their accessible priorities" ON "public"."activity";

DROP POLICY "Users can view activities in their accessible priorities" ON "public"."activity";

DROP POLICY "Users can insert activity exceptions for accessible activities" ON "public"."activity_exception";

DROP POLICY "Users can update activity exceptions for their own activities" ON "public"."activity_exception";

DROP POLICY "Users can view activity exceptions for accessible activities" ON "public"."activity_exception";

DROP POLICY "Users can delete their own activity read records" ON "public"."activity_read";

DROP POLICY "Users can insert their own activity read records" ON "public"."activity_read";

DROP POLICY "Users can update their own activity read records" ON "public"."activity_read";

DROP POLICY "Users can view their own activity read records" ON "public"."activity_read";

DROP POLICY "Users can insert activity_tag for activities in their accessibl" ON "public"."activity_tag";

DROP POLICY "Users can update activity_tag for activities in their accessibl" ON "public"."activity_tag";

DROP POLICY "Users can view activity_tag in their accessible priorities" ON "public"."activity_tag";

DROP POLICY "Users can view contacts linked to their priorities" ON "public"."contact";

DROP POLICY "Users can view their own contact record" ON "public"."contact";

DROP POLICY "Users can insert notes for accessible activities" ON "public"."note";

DROP POLICY "Users can update notes for accessible activities" ON "public"."note";

DROP POLICY "Users can view notes for accessible activities" ON "public"."note";

DROP POLICY "Users can insert note_tag for notes in their accessible priorit" ON "public"."note_tag";

DROP POLICY "Users can update note_tag for notes in their accessible priorit" ON "public"."note_tag";

DROP POLICY "Users can view note_tag in their accessible priorities" ON "public"."note_tag";

DROP POLICY "Users can access their priorities" ON "public"."priority";

DROP POLICY "Users can access priority contacts for their priorities" ON "public"."priority_contact";

DROP POLICY "Users can read/write their priority settings" ON "public"."priority_settings";

DROP POLICY "Users can insert twists in their accessible priorities" ON "public"."priority_twist";

DROP POLICY "Users can update twists in their accessible priorities" ON "public"."priority_twist";

DROP POLICY "Users can edit their own series" ON "public"."series";

DROP POLICY "Users can edit their sessions" ON "public"."session";

DROP POLICY "Users can create their own tokens" ON "public"."token";

DROP POLICY "Users can delete their own tokens" ON "public"."token";

DROP POLICY "Users can update their own tokens" ON "public"."token";

DROP POLICY "Users can view their own tokens" ON "public"."token";

DROP POLICY "Users can view accessible twists" ON "public"."twist";

DROP POLICY "Users can view accessible twist admins" ON "public"."twist_admin";

DROP POLICY "Users can read/write their settings" ON "public"."user_settings";

DROP POLICY "user_subscription_select_own" ON "public"."user_subscription";

SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.can_access_priority (_priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.user_priority_expanded upe
            WHERE
                upe.user_id = (
                    SELECT
                        auth.uid ())
                    AND upe.priority_id = _priority_id);
$function$;

CREATE OR REPLACE FUNCTION public.can_access_priority (_priority_path ltree)
    RETURNS boolean
    LANGUAGE sql
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.priority_user pu
                JOIN public.priority p ON p.id = pu.priority_id
            WHERE
                pu.user_id = (
                    SELECT
                        auth.uid ())
                    AND pu.archived_at IS NULL
                    AND p.path @> _priority_path);
$function$;

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR INSERT TO public
        WITH CHECK (((author_id = user_contact_id ()) AND user_has_priority_access ((
            SELECT
                auth.uid () AS uid), priority_id)));

CREATE POLICY "Users can update activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR UPDATE TO public
        USING ((user_has_priority_access ((
            SELECT
                auth.uid () AS uid), priority_id) AND ((draft = FALSE) OR (created_by = (
                    SELECT
                        auth.uid () AS uid))) AND ((private = FALSE) OR (created_by = (
                            SELECT
                                auth.uid () AS uid)) OR user_mentioned_in_activity ((
                                    SELECT
                                        auth.uid () AS uid), id))))
                                        WITH CHECK ((user_has_priority_access ((
                                            SELECT
                                                auth.uid () AS uid), priority_id) AND ((draft = FALSE) OR (created_by = (
                                                    SELECT
                                                        auth.uid () AS uid))) AND ((private = FALSE) OR (created_by = (
                                                            SELECT
                                                                auth.uid () AS uid)) OR user_mentioned_in_activity ((
                                                                    SELECT
                                                                        auth.uid () AS uid), id))));

CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR SELECT TO public
        USING ((user_has_priority_access ((
            SELECT
                auth.uid () AS uid), priority_id) AND ((draft = FALSE) OR (created_by = (
                    SELECT
                        auth.uid () AS uid))) AND ((private = FALSE) OR (created_by = (
                            SELECT
                                auth.uid () AS uid)) OR user_mentioned_in_activity ((
                                    SELECT
                                        auth.uid () AS uid), id))));

CREATE POLICY "Users can insert activity exceptions for accessible activities" ON "public"."activity_exception" AS permissive
    FOR INSERT TO public
        WITH CHECK ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access ((
                SELECT
                    auth.uid () AS uid), activity.priority_id)))));

CREATE POLICY "Users can update activity exceptions for their own activities" ON "public"."activity_exception" AS permissive
    FOR UPDATE TO public
        USING ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access ((
                SELECT
                    auth.uid () AS uid), activity.priority_id)))))
                    WITH CHECK ((EXISTS (
                        SELECT
                            1
                        FROM
                            activity
                        WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access ((
                            SELECT
                                auth.uid () AS uid), activity.priority_id)))));

CREATE POLICY "Users can view activity exceptions for accessible activities" ON "public"."activity_exception" AS permissive
    FOR SELECT TO public
        USING ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access ((
                SELECT
                    auth.uid () AS uid), activity.priority_id)))));

CREATE POLICY "Users can delete their own activity read records" ON "public"."activity_read" AS permissive
    FOR DELETE TO public
        USING ((user_id = (
            SELECT
                auth.uid () AS uid)));

CREATE POLICY "Users can insert their own activity read records" ON "public"."activity_read" AS permissive
    FOR INSERT TO public
        WITH CHECK ((user_id = (
            SELECT
                auth.uid () AS uid)));

CREATE POLICY "Users can update their own activity read records" ON "public"."activity_read" AS permissive
    FOR UPDATE TO public
        USING ((user_id = (
            SELECT
                auth.uid () AS uid)));

CREATE POLICY "Users can view their own activity read records" ON "public"."activity_read" AS permissive
    FOR SELECT TO public
        USING ((user_id = (
            SELECT
                auth.uid () AS uid)));

CREATE POLICY "Users can insert activity_tag for activities in their accessibl" ON "public"."activity_tag" AS permissive
    FOR INSERT TO public
        WITH CHECK (((actor_id = user_contact_id ()) AND (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access ((
                SELECT
                    auth.uid () AS uid), a.priority_id))))));

CREATE POLICY "Users can update activity_tag for activities in their accessibl" ON "public"."activity_tag" AS permissive
    FOR UPDATE TO public
        USING (((actor_id = user_contact_id ()) OR (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access ((
                SELECT
                    auth.uid () AS uid), a.priority_id) AND (get_tag_type (activity_tag.tag_id) = 'toggle'::tag_type))))))
                    WITH CHECK ((actor_id = user_contact_id ()));

CREATE POLICY "Users can view activity_tag in their accessible priorities" ON "public"."activity_tag" AS permissive
    FOR SELECT TO public
        USING (((actor_id = user_contact_id ()) OR (EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE ((a.id = activity_tag.activity_id) AND user_has_priority_access ((
                SELECT
                    auth.uid () AS uid), a.priority_id))))));

CREATE POLICY "Users can view contacts linked to their priorities" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING ((EXISTS (
            SELECT
                1
            FROM
                priority_contact pc
            WHERE ((pc.contact_id = contact.id) AND user_has_priority_access ((
                SELECT
                    auth.uid () AS uid), pc.priority_id)))));

CREATE POLICY "Users can view their own contact record" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING ((user_id = (
            SELECT
                auth.uid () AS uid)));

CREATE POLICY "Users can insert notes for accessible activities" ON "public"."note" AS permissive
    FOR INSERT TO public
        WITH CHECK (((author_id = user_contact_id ()) AND (EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access ((
                SELECT
                    auth.uid () AS uid), activity.priority_id))))));

CREATE POLICY "Users can update notes for accessible activities" ON "public"."note" AS permissive
    FOR UPDATE TO public
        USING (((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access ((
                SELECT
                    auth.uid () AS uid), activity.priority_id)))) AND ((draft = FALSE) OR (created_by = (
                        SELECT
                            auth.uid () AS uid))) AND ((private = FALSE) OR (created_by = (
                                SELECT
                                    auth.uid () AS uid)) OR ((
                                        SELECT
                                            auth.uid () AS uid) = ANY (mentions)))))
                                            WITH CHECK (((EXISTS (
                                                SELECT
                                                    1
                                                FROM
                                                    activity
                                                WHERE ((activity.id = note.activity_id) AND user_has_priority_access ((
                                                    SELECT
                                                        auth.uid () AS uid), activity.priority_id)))) AND ((draft = FALSE) OR (created_by = (
                                                            SELECT
                                                                auth.uid () AS uid))) AND ((private = FALSE) OR (created_by = (
                                                                    SELECT
                                                                        auth.uid () AS uid)) OR ((
                                                                            SELECT
                                                                                auth.uid () AS uid) = ANY (mentions)))));

CREATE POLICY "Users can view notes for accessible activities" ON "public"."note" AS permissive
    FOR SELECT TO public
        USING (((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = note.activity_id) AND user_has_priority_access ((
                SELECT
                    auth.uid () AS uid), activity.priority_id)))) AND ((draft = FALSE) OR (created_by = (
                        SELECT
                            auth.uid () AS uid))) AND ((private = FALSE) OR (created_by = (
                                SELECT
                                    auth.uid () AS uid)) OR ((
                                        SELECT
                                            auth.uid () AS uid) = ANY (mentions)))));

CREATE POLICY "Users can insert note_tag for notes in their accessible priorit" ON "public"."note_tag" AS permissive
    FOR INSERT TO public
        WITH CHECK (((actor_id = user_contact_id ()) AND (EXISTS (
            SELECT
                1
            FROM (note n
            JOIN activity a ON (a.id = n.activity_id))
        WHERE ((n.id = note_tag.note_id) AND user_has_priority_access ((
            SELECT
                auth.uid () AS uid), a.priority_id))))));

CREATE POLICY "Users can update note_tag for notes in their accessible priorit" ON "public"."note_tag" AS permissive
    FOR UPDATE TO public
        USING (((actor_id = user_contact_id ()) OR (EXISTS (
            SELECT
                1
            FROM (note n
            JOIN activity a ON (a.id = n.activity_id))
        WHERE ((n.id = note_tag.note_id) AND user_has_priority_access ((
            SELECT
                auth.uid () AS uid), a.priority_id) AND (get_tag_type (note_tag.tag_id) = 'toggle'::tag_type))))))
                WITH CHECK ((actor_id = user_contact_id ()));

CREATE POLICY "Users can view note_tag in their accessible priorities" ON "public"."note_tag" AS permissive
    FOR SELECT TO public
        USING (((actor_id = user_contact_id ()) OR (EXISTS (
            SELECT
                1
            FROM (note n
            JOIN activity a ON (a.id = n.activity_id))
        WHERE ((n.id = note_tag.note_id) AND user_has_priority_access ((
            SELECT
                auth.uid () AS uid), a.priority_id))))));

CREATE POLICY "Users can access their priorities" ON "public"."priority" AS permissive
    FOR SELECT TO authenticated
        USING ((can_access_priority (id) OR (created_by = (
            SELECT
                auth.uid () AS uid))));

CREATE POLICY "Users can access priority contacts for their priorities" ON "public"."priority_contact" AS permissive
    FOR ALL TO authenticated
        USING (user_has_priority_access ((
            SELECT
                auth.uid () AS uid), priority_id));

CREATE POLICY "Users can read/write their priority settings" ON "public"."priority_settings" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = (
            SELECT
                auth.uid () AS uid)));

CREATE POLICY "Users can insert twists in their accessible priorities" ON "public"."priority_twist" AS permissive
    FOR INSERT TO authenticated
        WITH CHECK ((can_access_priority (priority_id) AND (owner_id = (
            SELECT
                auth.uid () AS uid))));

CREATE POLICY "Users can update twists in their accessible priorities" ON "public"."priority_twist" AS permissive
    FOR UPDATE TO authenticated
        USING (can_access_priority (priority_id))
        WITH CHECK ((can_access_priority (priority_id) AND (owner_id = (
            SELECT
                auth.uid () AS uid))));

CREATE POLICY "Users can edit their own series" ON "public"."series" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = (
            SELECT
                auth.uid () AS uid)));

CREATE POLICY "Users can edit their sessions" ON "public"."session" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = (
            SELECT
                auth.uid () AS uid)));

CREATE POLICY "Users can create their own tokens" ON "public"."token" AS permissive
    FOR INSERT TO public
        WITH CHECK (((
            SELECT
                auth.uid () AS uid) = user_id));

CREATE POLICY "Users can delete their own tokens" ON "public"."token" AS permissive
    FOR DELETE TO public
        USING (((
            SELECT
                auth.uid () AS uid) = user_id));

CREATE POLICY "Users can update their own tokens" ON "public"."token" AS permissive
    FOR UPDATE TO public
        USING (((
            SELECT
                auth.uid () AS uid) = user_id))
                WITH CHECK (((
                    SELECT
                        auth.uid () AS uid) = user_id));

CREATE POLICY "Users can view their own tokens" ON "public"."token" AS permissive
    FOR SELECT TO public
        USING (((
            SELECT
                auth.uid () AS uid) = user_id));

CREATE POLICY "Users can view accessible twists" ON "public"."twist" AS permissive
    FOR SELECT TO authenticated
        USING (((environment = 'public'::twist_environment) OR (EXISTS (
            SELECT
                1
            FROM
                twist_admin ta
            WHERE ((ta.id = twist.twist_admin_id) AND (((twist.environment = 'personal'::twist_environment) AND (ta.user_id = (
                SELECT
                    auth.uid () AS uid))) OR ((twist.environment <> 'personal'::twist_environment) AND (ta.user_id IS NULL) AND ((ta.priority_id IS NULL) OR can_access_priority (ta.priority_id)))))))));

CREATE POLICY "Users can view accessible twist admins" ON "public"."twist_admin" AS permissive
    FOR SELECT TO authenticated
        USING (((user_id = (
            SELECT
                auth.uid () AS uid)) OR ((user_id IS NULL) AND ((priority_id IS NULL) OR can_access_priority (priority_id)))));

CREATE POLICY "Users can read/write their settings" ON "public"."user_settings" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = (
            SELECT
                auth.uid () AS uid)));

CREATE POLICY "user_subscription_select_own" ON "public"."user_subscription" AS permissive
    FOR SELECT TO authenticated
        USING (((
            SELECT
                auth.uid () AS uid) = user_id));

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
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
