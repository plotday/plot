ALTER TABLE "public"."user"
    ALTER COLUMN "timezone" SET DEFAULT 'America/New_York'::text;

UPDATE
    public.user
SET
    timezone = 'America/New_York'
WHERE
    timezone IS NULL;

ALTER TABLE "public"."user"
    ALTER COLUMN "timezone" SET NOT NULL;

