ALTER TABLE "public"."note" ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can edit notes in their categories" ON "public"."note" AS permissive
    FOR ALL TO authenticated
        USING (category_id IN (
            SELECT
                category.id
            FROM
                category
            WHERE
                category.user_id = get_user_id ()));

