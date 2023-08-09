ALTER TABLE "public"."calendar" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own calendars" ON "public"."calendar" AS permissive
    FOR SELECT TO authenticated
        USING ((account_id IN (
            SELECT
                account.id
            FROM
                account
            WHERE (account.auth_user_id = auth.uid ()))));

