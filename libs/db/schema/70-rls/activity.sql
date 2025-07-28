-- Activity RLS policies
CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity"
    FOR SELECT
        USING (public.user_has_priority_access(auth.uid(), activity.priority_id));

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity"
    FOR INSERT
        WITH CHECK (created_by = auth.uid ()
        AND public.user_has_priority_access(auth.uid(), activity.priority_id));

CREATE POLICY "Users can update their own activities" ON "public"."activity"
    FOR UPDATE
        USING (created_by = auth.uid ()
            AND public.user_has_priority_access(auth.uid(), activity.priority_id));

CREATE POLICY "Users can delete their own activities" ON "public"."activity"
    FOR DELETE
        USING (created_by = auth.uid ()
            AND public.user_has_priority_access(auth.uid(), activity.priority_id));


