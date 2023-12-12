ALTER TABLE "public"."budget" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read/write their budgets" ON "public"."budget" AS permissive
    FOR ALL TO authenticated
        USING (is_user_account (auth.uid (), (
            SELECT
                user_id
            FROM
                category
            WHERE
                id = category_id)));

