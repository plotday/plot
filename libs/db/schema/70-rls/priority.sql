-- Allow access to priority rows based on user's access
-- Also allow users to see priorities they created (needed for RETURNING clause before priority_user trigger runs)
CREATE POLICY "Users can access their priorities" ON public.priority
    FOR SELECT TO authenticated
        USING (can_access_priority (id) OR created_by = auth.uid ());

CREATE POLICY "Users change sharing for their priorities" ON public.priority_user
    FOR ALL TO authenticated
        USING (can_access_priority (priority_id));

CREATE POLICY "Users can create new priorities in their priorities" ON public.priority
    FOR INSERT TO authenticated
        WITH CHECK (can_access_priority (parent_path (priority.path)));

CREATE POLICY "Users can update their priorities" ON public.priority
    FOR UPDATE TO authenticated
        USING (can_access_priority (id)
            AND (priority.archived_at IS NULL
                OR NOT EXISTS (
                    SELECT 1
                    FROM priority_user
                    WHERE priority_user.priority_id = priority.id
                        AND priority_user.personal = TRUE
                )))
            WITH CHECK (nlevel (priority.path) = 1
            OR can_access_priority (parent_path (priority.path)));

CREATE POLICY "Users can read/write their priority settings" ON "public"."priority_settings"
    FOR ALL TO authenticated
        USING (user_id = auth.uid ());

