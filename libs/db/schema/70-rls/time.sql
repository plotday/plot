CREATE POLICY "Users can edit their time" ON "public"."time" AS permissive
    FOR ALL TO authenticated
        USING (user_id = auth.uid ());

