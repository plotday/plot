-- Allow access to priority rows based on user's access
-- Also allow users to see priorities they created (needed for RETURNING clause before priority_user trigger runs)
CREATE POLICY "Users can access their priorities" ON public.priority
    FOR SELECT TO authenticated
        USING (can_access_priority (id) OR created_by = (select auth.uid ()));

-- Split into separate policies to break circular dependency for initial root priority
-- Allow users to see their own priority_user entries without requiring can_access_priority
CREATE POLICY "Users can view their priority access" ON public.priority_user
    FOR SELECT TO authenticated
        USING (user_id = (SELECT auth.uid ()) OR can_access_priority (priority_id));

-- Restrict INSERT to priorities they have access to
CREATE POLICY "Users can add priority sharing" ON public.priority_user
    FOR INSERT TO authenticated
        WITH CHECK (can_access_priority (priority_id));

-- Restrict UPDATE to priorities they have access to
CREATE POLICY "Users can modify priority sharing" ON public.priority_user
    FOR UPDATE TO authenticated
        USING (can_access_priority (priority_id));

-- Restrict DELETE to priorities they have access to
CREATE POLICY "Users can remove priority sharing" ON public.priority_user
    FOR DELETE TO authenticated
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
        USING (user_id = (select auth.uid ()));

