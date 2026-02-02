-- Activity RLS policies
CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity"
    FOR SELECT
        USING (public.user_has_priority_access ((select auth.uid ()), activity.priority_id)
        -- Draft filtering: only creator can see drafts
            AND (activity.draft = FALSE OR activity.created_by = (select auth.uid ()))
            -- Private filtering: CASE guarantees short-circuit so user_mentioned_in_activity
            -- only runs when private = TRUE and the user is not the creator
            AND (CASE WHEN activity.private = FALSE THEN TRUE
                WHEN activity.created_by = (select auth.uid ()) THEN TRUE
                ELSE public.user_mentioned_in_activity ((select auth.uid ()), activity.id)
            END));

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity"
    FOR INSERT
        WITH CHECK (author_id = user_contact_id ()
        AND public.user_has_priority_access ((select auth.uid ()), activity.priority_id));

CREATE POLICY "Users can update activities in their accessible priorities" ON "public"."activity"
    FOR UPDATE
        USING (public.user_has_priority_access ((select auth.uid ()), activity.priority_id)
        -- Draft filtering: only creator can update drafts
            AND (activity.draft = FALSE OR activity.created_by = (select auth.uid ()))
            -- Private filtering: CASE guarantees short-circuit evaluation
            AND (CASE WHEN activity.private = FALSE THEN TRUE
                WHEN activity.created_by = (select auth.uid ()) THEN TRUE
                ELSE public.user_mentioned_in_activity ((select auth.uid ()), activity.id)
            END))
            WITH CHECK (public.user_has_priority_access ((select auth.uid ()), activity.priority_id)
            -- Draft filtering: only creator can update drafts
            AND (activity.draft = FALSE OR activity.created_by = (select auth.uid ()))
            -- Private filtering: CASE guarantees short-circuit evaluation
            AND (CASE WHEN activity.private = FALSE THEN TRUE
                WHEN activity.created_by = (select auth.uid ()) THEN TRUE
                ELSE public.user_mentioned_in_activity ((select auth.uid ()), activity.id)
            END));

-- Activity Exception RLS policies
CREATE POLICY "Users can view activity exceptions for accessible activities" ON "public"."activity_exception"
    FOR SELECT
        USING (EXISTS (
            SELECT
                1
            FROM
                public.activity
            WHERE
                activity.id = activity_exception.activity_id AND public.user_has_priority_access ((select auth.uid ()), activity.priority_id)));

CREATE POLICY "Users can insert activity exceptions for accessible activities" ON "public"."activity_exception"
    FOR INSERT
        WITH CHECK (EXISTS (
            SELECT
                1
            FROM
                public.activity
            WHERE
                activity.id = activity_exception.activity_id AND public.user_has_priority_access ((select auth.uid ()), activity.priority_id)));

CREATE POLICY "Users can update activity exceptions for their own activities" ON "public"."activity_exception"
    FOR UPDATE
        USING (EXISTS (
            SELECT
                1
            FROM
                public.activity
            WHERE
                activity.id = activity_exception.activity_id AND public.user_has_priority_access ((select auth.uid ()), activity.priority_id)))
            WITH CHECK (EXISTS (
                SELECT
                    1
                FROM
                    public.activity
                WHERE
                    activity.id = activity_exception.activity_id AND public.user_has_priority_access ((select auth.uid ()), activity.priority_id)));

