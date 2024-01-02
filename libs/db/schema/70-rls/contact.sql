CREATE POLICY "Users can view their contact" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING (user_id = auth.uid ());

