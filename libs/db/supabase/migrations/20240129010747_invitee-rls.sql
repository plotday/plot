DROP POLICY "Users can view their invitees for their events" ON "public"."invitee";

CREATE POLICY "Users can edit their invitees for their events" ON "public"."invitee" AS permissive
    FOR ALL TO authenticated
        USING ((event_id IN (
            SELECT
                event.id
            FROM
                event)));

