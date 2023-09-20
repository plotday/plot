ALTER TABLE "public"."invitee" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their invitees for their events" ON "public"."invitee" AS permissive
    FOR SELECT TO authenticated
        USING (event_id IN (
            SELECT
                id
            FROM
                public.event));

CREATE POLICY "Users can update their invitees for their events" ON "public"."invitee" AS permissive
    FOR UPDATE TO authenticated
        USING (event_id IN (
            SELECT
                id
            FROM
                public.event));

