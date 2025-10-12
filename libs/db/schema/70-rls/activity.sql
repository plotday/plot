-- Activity RLS policies
CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity"
    FOR SELECT
        USING (public.user_has_priority_access (auth.uid (), activity.priority_id));

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity"
    FOR INSERT
        WITH CHECK (author_id = user_contact_id ()
        AND public.user_has_priority_access (auth.uid (), activity.priority_id));

CREATE POLICY "Users can update activities in their accessible priorities" ON "public"."activity"
    FOR UPDATE
        USING (public.user_has_priority_access (auth.uid (), activity.priority_id))
        WITH CHECK (public.user_has_priority_access (auth.uid (), activity.priority_id));

-- Activity Exception RLS policies
CREATE POLICY "Users can view activity exceptions for accessible activities" ON "public"."activity_exception"
    FOR SELECT
        USING (EXISTS (
            SELECT
                1
            FROM
                public.activity
            WHERE
                activity.id = activity_exception.activity_id AND public.user_has_priority_access (auth.uid (), activity.priority_id)));

CREATE POLICY "Users can insert activity exceptions for accessible activities" ON "public"."activity_exception"
    FOR INSERT
        WITH CHECK (EXISTS (
            SELECT
                1
            FROM
                public.activity
            WHERE
                activity.id = activity_exception.activity_id AND public.user_has_priority_access (auth.uid (), activity.priority_id)));

CREATE POLICY "Users can update activity exceptions for their own activities" ON "public"."activity_exception"
    FOR UPDATE
        USING (EXISTS (
            SELECT
                1
            FROM
                public.activity
            WHERE
                activity.id = activity_exception.activity_id AND public.user_has_priority_access (auth.uid (), activity.priority_id)))
            WITH CHECK (EXISTS (
                SELECT
                    1
                FROM
                    public.activity
                WHERE
                    activity.id = activity_exception.activity_id AND public.user_has_priority_access (auth.uid (), activity.priority_id)));

