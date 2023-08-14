ALTER TABLE "public"."waitlist" ENABLE ROW LEVEL SECURITY;

BEGIN;
CREATE POLICY "Retool can access full waitlist" ON "public"."waitlist" AS permissive TO retool
    USING (TRUE);
COMMIT;

