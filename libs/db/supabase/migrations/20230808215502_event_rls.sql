CREATE POLICY "Users can view their own calendars" ON "public"."calendar" AS permissive
    FOR SELECT TO authenticated
        USING ((account_id IN (
            SELECT
                account.id
            FROM
                account
            WHERE (account.auth_user_id = auth.uid ()))));

CREATE POLICY "Users can view their own events" ON "public"."event" AS permissive
    FOR SELECT TO authenticated
        USING ((calendar_id IN (
            SELECT
                calendar.id
            FROM
                calendar
            WHERE (calendar.account_id IN (
                SELECT
                    account.id
                FROM
                    account
                WHERE (account.auth_user_id = auth.uid ()))))));

