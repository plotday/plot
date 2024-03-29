CREATE POLICY "Users can read/write their priorities" ON "public"."priority" AS permissive
    FOR ALL TO authenticated
        USING (user_id = auth.uid ());

