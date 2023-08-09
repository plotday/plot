DROP POLICY "Users can view their own calendars" ON "public"."calendar";

DROP POLICY "Users can view their own events" ON "public"."event";

CREATE POLICY "Users can view their contact" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING ((user_id IN (
            SELECT
                "user".id
            FROM
                "user")));

CREATE POLICY "Users can view their invitees for their events" ON "public"."invitee" AS permissive
    FOR SELECT TO authenticated
        USING ((event_id IN (
            SELECT
                event.id
            FROM
                event)));

CREATE POLICY "Users can view their own calendars" ON "public"."calendar" AS permissive
    FOR SELECT TO authenticated
        USING ((account_id IN (
            SELECT
                account.id
            FROM
                account)));

CREATE POLICY "Users can view their own events" ON "public"."event" AS permissive
    FOR SELECT TO authenticated
        USING ((calendar_id IN (
            SELECT
                calendar.id
            FROM
                calendar)));

