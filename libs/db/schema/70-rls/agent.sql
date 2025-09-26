CREATE POLICY "Allow all users to view agents" ON "public"."agent"
    FOR SELECT TO authenticated
        USING (TRUE);

CREATE POLICY "Users can edit agents in their accessible priorities" ON "public"."priority_agent"
    FOR ALL TO authenticated
        USING (can_access_priority (priority_id));


