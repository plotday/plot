ALTER TABLE "public"."invitation" ENABLE ROW LEVEL SECURITY;

BEGIN;
CREATE POLICY "Retool can access all invitations" ON "public"."invitation" AS permissive TO retool
    USING (TRUE);
COMMIT;

