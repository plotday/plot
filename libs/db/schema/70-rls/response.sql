ALTER TABLE "public"."response" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can edit their own responses" ON "public"."response" AS permissive
    FOR ALL TO authenticated
        USING (is_user_account (auth.uid (), user_id));

