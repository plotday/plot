CREATE POLICY "Users can read/write their activities" ON "public"."activity" AS permissive
    FOR ALL TO authenticated
        USING (user_id = auth.uid ());

