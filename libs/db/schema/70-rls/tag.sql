-- activity_tag RLS policies
CREATE POLICY "Users can view activity_tag in their accessible priorities" ON "public"."activity_tag"
    FOR SELECT
        USING (user_id = auth.uid ()
            OR EXISTS (
                SELECT
                    1
                FROM
                    activity a
                WHERE
                    a.id = activity_tag.activity_id AND public.user_has_priority_access (auth.uid (), a.priority_id)));

CREATE POLICY "Users can insert activity_tag for activities in their accessible priorities" ON "public"."activity_tag"
    FOR INSERT
        WITH CHECK (user_id = auth.uid ()
        AND EXISTS (
            SELECT
                1
            FROM
                activity a
            WHERE
                a.id = activity_tag.activity_id AND public.user_has_priority_access (auth.uid (), a.priority_id)));

REVOKE UPDATE ON TABLE public.activity_tag FROM authenticated;

GRANT UPDATE (updated_at, updated_by, deleted_at) ON TABLE public.activity_tag TO authenticated;

CREATE POLICY "Users can update activity_tag for activities in their accessible priorities" ON "public"."activity_tag"
    FOR UPDATE
        USING (user_id = auth.uid ()
            OR EXISTS (
                SELECT
                    1
                FROM
                    activity a
                WHERE
                    a.id = activity_tag.activity_id 
                    AND public.user_has_priority_access (auth.uid (), a.priority_id) 
                    AND get_tag_type(activity_tag.tag_id) = 'toggle'))
                WITH CHECK (activity_tag.user_id = auth.uid ());

