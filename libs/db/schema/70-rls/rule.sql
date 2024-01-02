CREATE POLICY "Users can edit their rules" ON "public"."rule" AS permissive
    FOR ALL TO authenticated
        USING (user_id = auth.uid ());

