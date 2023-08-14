ALTER TABLE "public"."invitation" ENABLE ROW LEVEL SECURITY;

BEGIN;
CREATE POLICY "internal_admin can access all invitations" ON "public"."invitation" AS permissive TO internal_admin
    USING (TRUE);
COMMIT;

