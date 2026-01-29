-- Activity Read RLS policies
CREATE POLICY "Users can view their own activity read records" ON "public"."activity_read"
    FOR SELECT
        USING (user_id = (select auth.uid ()));

CREATE POLICY "Users can insert their own activity read records" ON "public"."activity_read"
    FOR INSERT
        WITH CHECK (user_id = (select auth.uid ()));

CREATE POLICY "Users can update their own activity read records" ON "public"."activity_read"
    FOR UPDATE
        USING (user_id = (select auth.uid ()));

CREATE POLICY "Users can delete their own activity read records" ON "public"."activity_read"
    FOR DELETE
        USING (user_id = (select auth.uid ()));
