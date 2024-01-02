CREATE POLICY "Users can read their accounts" ON "public"."account" AS permissive
    FOR SELECT TO authenticated
        USING (user_id = auth.uid ());

