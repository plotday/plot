-- Allow users with priority access to view/manage priority contacts
CREATE POLICY "Users can access priority contacts for their priorities" ON public.priority_contact
    FOR ALL TO authenticated
        USING (public.user_has_priority_access ((select auth.uid ()), priority_id));


