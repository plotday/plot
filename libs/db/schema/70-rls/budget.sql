CREATE POLICY "Users can read/write their budgets" ON "public"."budget" AS permissive
    FOR ALL TO authenticated
        USING (user_id = auth.uid ());

