ALTER TABLE "public"."account" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read their accounts" ON "public"."account" AS permissive
    FOR SELECT TO authenticated
        USING (((auth_user_id = auth.uid ()) OR is_user_account (auth.uid (), id)));

