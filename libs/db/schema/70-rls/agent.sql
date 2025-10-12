-- Users can view accessible agents
-- Public agents, personal agents they own, or agents in priorities they can access
CREATE POLICY "Users can view accessible agents" ON "public"."agent"
    FOR SELECT TO authenticated
        USING (environment = 'public'
            OR (environment = 'personal' AND user_id = auth.uid ())
            OR EXISTS (
                SELECT
                    1
                FROM
                    agent_admin aa
                WHERE
                    aa.id = agent.id AND can_access_priority (aa.priority_id)));

-- Users can view agents in their accessible priorities
CREATE POLICY "Users can view agents in their accessible priorities" ON "public"."priority_agent"
    FOR SELECT TO authenticated
        USING (can_access_priority (priority_id));

-- Users can insert agents in their accessible priorities (owner_id set by trigger)
CREATE POLICY "Users can insert agents in their accessible priorities" ON "public"."priority_agent"
    FOR INSERT TO authenticated
        WITH CHECK (can_access_priority (priority_id)
        AND owner_id = auth.uid ());

-- Users can update agents in their accessible priorities, but cannot change owner_id to another user
-- The WITH CHECK ensures that owner_id can only be the current user's ID
CREATE POLICY "Users can update agents in their accessible priorities" ON "public"."priority_agent"
    FOR UPDATE TO authenticated
        USING (can_access_priority (priority_id))
        WITH CHECK (can_access_priority (priority_id)
            AND owner_id = auth.uid ());

-- Users can delete agents in their accessible priorities
CREATE POLICY "Users can delete agents in their accessible priorities" ON "public"."priority_agent"
    FOR DELETE TO authenticated
        USING (can_access_priority (priority_id));

