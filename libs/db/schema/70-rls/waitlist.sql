CREATE POLICY "internal_admin can edit the wailist" ON "public"."waitlist" AS permissive TO internal_admin
    USING (TRUE);

