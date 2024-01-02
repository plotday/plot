CREATE POLICY "Users can view their own calendars" ON "public"."calendar" AS permissive
    FOR SELECT TO authenticated
        USING ((account_id IN (
            SELECT
                account.id
            FROM
                account)));

