-- Note RLS policies
CREATE POLICY "Users can view notes for accessible activities" ON "public"."note"
    FOR SELECT
        USING (EXISTS (
            SELECT
                1
            FROM
                public.activity
            WHERE
                activity.id = note.activity_id AND public.user_has_priority_access ((select auth.uid ()), activity.priority_id))
            -- Draft filtering: only creator can see drafts
            AND (note.draft = FALSE
                OR note.created_by = (select auth.uid ()))
            -- Private filtering: creator or mentioned users can see private notes
            AND (note.private = FALSE
                OR note.created_by = (select auth.uid ())
                OR (select auth.uid ()) = ANY (note.mentions)));

CREATE POLICY "Users can insert notes for accessible activities" ON "public"."note"
    FOR INSERT
        WITH CHECK (author_id = user_contact_id ()
        AND EXISTS (
            SELECT
                1
            FROM
                public.activity
            WHERE
                activity.id = note.activity_id AND public.user_has_priority_access ((select auth.uid ()), activity.priority_id)));

CREATE POLICY "Users can update notes for accessible activities" ON "public"."note"
    FOR UPDATE
        USING (EXISTS (
            SELECT
                1
            FROM
                public.activity
            WHERE
                activity.id = note.activity_id AND public.user_has_priority_access ((select auth.uid ()), activity.priority_id))
            -- Draft filtering: only creator can update drafts
            AND (note.draft = FALSE
                OR note.created_by = (select auth.uid ()))
            -- Private filtering: creator or mentioned users can update private notes
            AND (note.private = FALSE
                OR note.created_by = (select auth.uid ())
                OR (select auth.uid ()) = ANY (note.mentions)))
            WITH CHECK (EXISTS (
                SELECT
                    1
                FROM
                    public.activity
                WHERE
                    activity.id = note.activity_id AND public.user_has_priority_access ((select auth.uid ()), activity.priority_id))
            -- Draft filtering: only creator can update drafts
            AND (note.draft = FALSE
                OR note.created_by = (select auth.uid ()))
            -- Private filtering: creator or mentioned users can update private notes
            AND (note.private = FALSE
                OR note.created_by = (select auth.uid ())
                OR (select auth.uid ()) = ANY (note.mentions)));
