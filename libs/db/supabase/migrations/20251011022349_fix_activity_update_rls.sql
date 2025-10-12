DROP POLICY "Users can update their own activities" ON "public"."activity";

DROP POLICY "Users can update activity exceptions for their own activities" ON "public"."activity_exception";

CREATE POLICY "Users can update their own activities" ON "public"."activity" AS permissive
    FOR UPDATE TO public
        USING (((author_id = user_contact_id ()) AND user_has_priority_access (auth.uid (), priority_id)))
        WITH CHECK (user_has_priority_access (auth.uid (), priority_id));

CREATE POLICY "Users can update activity exceptions for their own activities" ON "public"."activity_exception" AS permissive
    FOR UPDATE TO public
        USING ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND (activity.author_id = user_contact_id ()) AND user_has_priority_access (auth.uid (), activity.priority_id)))))
        WITH CHECK ((EXISTS (
            SELECT
                1
            FROM
                activity
            WHERE ((activity.id = activity_exception.activity_id) AND user_has_priority_access (auth.uid (), activity.priority_id)))));

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_agent" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
