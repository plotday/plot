-- Users can view twist_admin entries they own or have priority access to
CREATE POLICY "Users can view accessible twist admins" ON "public"."twist_admin"
    FOR SELECT TO authenticated
        USING (
            -- Personal twist admins: user owns them
            user_id = auth.uid ()
            OR
            -- Non-personal twist admins: check priority access
            (user_id IS NULL AND (priority_id IS NULL OR can_access_priority (priority_id)))
        );

-- Users can view accessible twists
-- Public twists, personal twists they own, or twists in priorities they can access
CREATE POLICY "Users can view accessible twists" ON "public"."twist"
    FOR SELECT TO authenticated
        USING (environment = 'public'
            OR EXISTS (
                SELECT
                    1
                FROM
                    twist_admin ta
                WHERE
                    ta.id = twist.twist_admin_id
                    AND (
                        -- Personal twists: user owns them
                        (environment = 'personal' AND ta.user_id = auth.uid ())
                        OR
                        -- Non-personal twists: check priority access
                        (environment != 'personal' AND ta.user_id IS NULL AND (ta.priority_id IS NULL OR can_access_priority (ta.priority_id)))
                    )
            ));

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
-- Note: twist_id and owner_id immutability is enforced by the prevent_twist_immutable_changes trigger
CREATE POLICY "Users can update twists in their accessible priorities" ON "public"."priority_twist"
    FOR UPDATE TO authenticated
        USING (can_access_priority (priority_id))
        WITH CHECK (can_access_priority (priority_id)
            AND owner_id = auth.uid ());

-- Users can delete twists in their accessible priorities
CREATE POLICY "Users can delete twists in their accessible priorities" ON "public"."priority_twist"
    FOR DELETE TO authenticated
        USING (can_access_priority (priority_id));

