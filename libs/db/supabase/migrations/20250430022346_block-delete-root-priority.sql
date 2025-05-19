DROP POLICY "Users can update their priorities" ON "public"."priority";

CREATE POLICY "Users can update their priorities" ON "public"."priority" AS permissive
    FOR UPDATE TO authenticated
        USING ((can_access_priority (id) AND ((deleted_at IS NULL) OR (root = FALSE))))
        WITH CHECK (((nlevel (path) = 1) OR can_access_priority (parent_path (path))));

