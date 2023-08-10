ALTER TABLE "public"."account"
    DROP CONSTRAINT "account_user_provider_unique";

DROP INDEX IF EXISTS "public"."account_user_provider_unique";

