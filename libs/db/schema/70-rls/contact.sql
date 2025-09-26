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
                pc.contact_id = contact.id AND pc.deleted_at IS NULL AND public.user_has_priority_access (auth.uid (), pc.priority_id)));

