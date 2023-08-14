ALTER TABLE "public"."waitlist" ENABLE ROW LEVEL SECURITY;

BEGIN;
CREATE POLICY "internal_admin can access full waitlist" ON "public"."waitlist" AS permissive TO internal_admin
    USING (TRUE);
COMMIT;

