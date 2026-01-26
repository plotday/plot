-- Helper function to check if a user is mentioned in an activity's notes
-- SECURITY DEFINER to bypass RLS and avoid infinite recursion
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

-- Activity RLS policies
CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity"
    FOR SELECT
        USING (public.user_has_priority_access ((select auth.uid ()), activity.priority_id)
        -- Draft filtering: only creator can see drafts
            AND (activity.draft = FALSE OR activity.created_by = (select auth.uid ()))
            -- Private filtering: creator or mentioned users can see private items
            AND (activity.private = FALSE OR activity.created_by = (select auth.uid ()) OR public.user_mentioned_in_activity ((select auth.uid ()), activity.id)));

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity"
    FOR INSERT
        WITH CHECK (author_id = user_contact_id ()
        AND public.user_has_priority_access ((select auth.uid ()), activity.priority_id));

CREATE POLICY "Users can update activities in their accessible priorities" ON "public"."activity"
    FOR UPDATE
        USING (public.user_has_priority_access ((select auth.uid ()), activity.priority_id)
        -- Draft filtering: only creator can update drafts
            AND (activity.draft = FALSE OR activity.created_by = (select auth.uid ()))
            -- Private filtering: creator or mentioned users can update private items
            AND (activity.private = FALSE OR activity.created_by = (select auth.uid ()) OR public.user_mentioned_in_activity ((select auth.uid ()), activity.id)))
            WITH CHECK (public.user_has_priority_access ((select auth.uid ()), activity.priority_id)
            -- Draft filtering: only creator can update drafts
            AND (activity.draft = FALSE OR activity.created_by = (select auth.uid ()))
            -- Private filtering: creator or mentioned users can update private items
            AND (activity.private = FALSE OR activity.created_by = (select auth.uid ()) OR public.user_mentioned_in_activity ((select auth.uid ()), activity.id)));

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

