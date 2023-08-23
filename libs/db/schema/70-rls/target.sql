ALTER TABLE "public"."target" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own targets" ON "public"."target" AS permissive
    FOR ALL TO authenticated
        USING (is_user_account (auth.uid (), user_id));

