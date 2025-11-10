-- Users can view accessible twists
-- Public twists, personal twists they own, or twists in priorities they can access
CREATE POLICY "Users can view accessible twists" ON "public"."twist"
    FOR SELECT TO authenticated
        USING (environment = 'public'
            OR (environment = 'personal' AND user_id = auth.uid ())
            OR EXISTS (
                SELECT
                    1
                FROM
                    twist_admin ta
                WHERE
                    ta.id = twist.id AND can_access_priority (ta.priority_id)));

-- Users can view twists in their accessible priorities
CREATE POLICY "Users can view twists in their accessible priorities" ON "public"."priority_twist"
    FOR SELECT TO authenticated
        USING (can_access_priority (priority_id));

-- Users can insert twists in their accessible priorities (owner_id set by trigger)
CREATE POLICY "Users can insert twists in their accessible priorities" ON "public"."priority_twist"
    FOR INSERT TO authenticated
        WITH CHECK (can_access_priority (priority_id)
        AND owner_id = auth.uid ());

-- Users can update twists in their accessible priorities, but cannot change owner_id to another user
-- The WITH CHECK ensures that owner_id can only be the current user's ID
CREATE POLICY "Users can update twists in their accessible priorities" ON "public"."priority_twist"
    FOR UPDATE TO authenticated
        USING (can_access_priority (priority_id))
        WITH CHECK (can_access_priority (priority_id)
            AND owner_id = auth.uid ());

-- Users can delete twists in their accessible priorities
CREATE POLICY "Users can delete twists in their accessible priorities" ON "public"."priority_twist"
    FOR DELETE TO authenticated
        USING (can_access_priority (priority_id));

