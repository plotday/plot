-- Allow users to view their own contact record
CREATE POLICY "Users can view their own contact record" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING (user_id = (select auth.uid()));

-- Allow users to access contacts linked to priorities they can access
CREATE POLICY "Users can view contacts linked to their priorities" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING (
        -- Allow access to contacts linked to priorities the user can access
        EXISTS (
            SELECT
                1
            FROM
                public.priority_contact pc
            WHERE
                pc.contact_id = contact.id AND public.user_has_priority_access ((select auth.uid ()), pc.priority_id)));

