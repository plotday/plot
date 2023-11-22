ALTER TABLE "public"."category" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read/write their categories" ON "public"."category" AS permissive
    FOR ALL TO authenticated
        USING (is_user_account (auth.uid (), user_id));

