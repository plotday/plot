-- Activity RLS policies
CREATE POLICY "Users can view activities in their accessible priorities" ON "public"."activity"
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM priority_user pu
            JOIN priority p ON pu.priority_id = p.id OR (p.path <@ (SELECT path FROM priority WHERE id = pu.priority_id))
            WHERE pu.user_id = auth.uid()
            AND pu.deleted_at IS NULL
            AND p.deleted_at IS NULL
            AND activity.priority_id = p.id
        )
    );

CREATE POLICY "Users can insert activities in their accessible priorities" ON "public"."activity"
    FOR INSERT
    WITH CHECK (
        created_by = auth.uid()
        AND EXISTS (
            SELECT 1 FROM priority_user pu
            JOIN priority p ON pu.priority_id = p.id OR (p.path <@ (SELECT path FROM priority WHERE id = pu.priority_id))
            WHERE pu.user_id = auth.uid()
            AND pu.deleted_at IS NULL
            AND p.deleted_at IS NULL
            AND activity.priority_id = p.id
        )
    );

CREATE POLICY "Users can update their own activities" ON "public"."activity"
    FOR UPDATE
    USING (
        created_by = auth.uid()
        AND EXISTS (
            SELECT 1 FROM priority_user pu
            JOIN priority p ON pu.priority_id = p.id OR (p.path <@ (SELECT path FROM priority WHERE id = pu.priority_id))
            WHERE pu.user_id = auth.uid()
            AND pu.deleted_at IS NULL
            AND p.deleted_at IS NULL
            AND activity.priority_id = p.id
        )
    );

CREATE POLICY "Users can delete their own activities" ON "public"."activity"
    FOR DELETE
    USING (
        created_by = auth.uid()
        AND EXISTS (
            SELECT 1 FROM priority_user pu
            JOIN priority p ON pu.priority_id = p.id OR (p.path <@ (SELECT path FROM priority WHERE id = pu.priority_id))
            WHERE pu.user_id = auth.uid()
            AND pu.deleted_at IS NULL
            AND p.deleted_at IS NULL
            AND activity.priority_id = p.id
        )
    );