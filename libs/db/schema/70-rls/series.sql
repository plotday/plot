CREATE POLICY "Users can edit their own series" ON "public"."series" AS permissive
    FOR ALL TO authenticated
        USING (user_id = auth.uid ());

