ALTER TABLE "public"."user" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read themselves" ON "public"."user" AS permissive
    FOR SELECT TO authenticated
        USING ((auth.uid () IN (
            SELECT
                account.auth_user_id
            FROM
                account
            WHERE (account.user_id = "user".id))));

CREATE POLICY "internal_admin can edit all users" ON "public"."user" AS permissive TO internal_admin
    USING (TRUE);

