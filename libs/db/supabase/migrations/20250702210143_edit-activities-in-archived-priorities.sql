DROP POLICY "Users can delete their own activities" ON "public"."activity";

DROP POLICY "Users can insert activities in their accessible priorities" ON "public"."activity";

DROP POLICY "Users can update their own activities" ON "public"."activity";

DROP POLICY "Users can view activities in their accessible priorities" ON "public"."activity";

CREATE POLICY "Users can delete their own activities" ON "public"."activity" AS permissive
    FOR DELETE TO public
        USING (((created_by = auth.uid ()) AND (EXISTS (
            SELECT
                1
            FROM (priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id) OR (p.path <@ (
                    SELECT
                        priority.path
                    FROM
                        priority
                WHERE (priority.id = pu.priority_id))))))
            WHERE ((pu.user_id = auth.uid ()) AND (pu.deleted_at IS NULL) AND (activity.priority_id = p.id))))));

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR INSERT TO public
        WITH CHECK (((created_by = auth.uid ()) AND (EXISTS (
            SELECT
                1
            FROM (priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id) OR (p.path <@ (
                    SELECT
                        priority.path
                    FROM
                        priority
                WHERE (priority.id = pu.priority_id))))))
            WHERE ((pu.user_id = auth.uid ()) AND (pu.deleted_at IS NULL) AND (activity.priority_id = p.id))))));

CREATE POLICY "Users can update their own activities" ON "public"."activity" AS permissive
    FOR UPDATE TO public
        USING (((created_by = auth.uid ()) AND (EXISTS (
            SELECT
                1
            FROM (priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id) OR (p.path <@ (
                    SELECT
                        priority.path
                    FROM
                        priority
                WHERE (priority.id = pu.priority_id))))))
            WHERE ((pu.user_id = auth.uid ()) AND (pu.deleted_at IS NULL) AND (activity.priority_id = p.id))))));

CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity" AS permissive
    FOR SELECT TO public
        USING ((EXISTS (
            SELECT
                1
            FROM (priority_user pu
            JOIN priority p ON (((pu.priority_id = p.id) OR (p.path <@ (
                    SELECT
                        priority.path
                    FROM
                        priority
                WHERE (priority.id = pu.priority_id))))))
            WHERE ((pu.user_id = auth.uid ()) AND (pu.deleted_at IS NULL) AND (activity.priority_id = p.id)))));

ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW gap SET ( security_invoker = TRUE);
ALTER VIEW gap_monthly SET ( security_invoker = TRUE);
ALTER VIEW gap_daily SET ( security_invoker = TRUE);
ALTER VIEW insight SET ( security_invoker = TRUE);
ALTER VIEW "admin"."sync" SET ( security_invoker = FALSE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."event_invitees" SET ( security_invoker = TRUE);
ALTER VIEW "public"."event_x" SET ( security_invoker = TRUE);
ALTER VIEW public.calendar_x SET ( security_invoker = TRUE);
ALTER VIEW "admin"."user" SET ( security_invoker = FALSE);
ALTER VIEW balance_without_children SET ( security_invoker = TRUE);
ALTER VIEW balance SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_children" SET ( security_invoker = TRUE);
