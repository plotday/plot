-- Rename 'business' → 'team' in subscription_plan enum

-- 1. Drop defaults that reference the enum type
ALTER TABLE "public"."user_subscription" ALTER COLUMN "plan" DROP DEFAULT;
ALTER TABLE "public"."organization_subscription" ALTER COLUMN "plan" DROP DEFAULT;

-- 2. Convert columns to text
ALTER TABLE "public"."user_subscription"
  ALTER COLUMN "plan" TYPE text;
ALTER TABLE "public"."organization_subscription"
  ALTER COLUMN "plan" TYPE text;

-- 3. Migrate data
UPDATE user_subscription SET plan = 'team' WHERE plan = 'business';
UPDATE organization_subscription SET plan = 'team' WHERE plan = 'business';

-- 4. Drop old enum and create new one
DROP TYPE "public"."subscription_plan";
CREATE TYPE "public"."subscription_plan" AS ENUM ('free', 'pro', 'team');

-- 5. Convert columns back to enum with defaults
ALTER TABLE "public"."user_subscription"
  ALTER COLUMN "plan" TYPE "public"."subscription_plan"
  USING plan::"public"."subscription_plan";
ALTER TABLE "public"."user_subscription"
  ALTER COLUMN "plan" SET DEFAULT 'free';

ALTER TABLE "public"."organization_subscription"
  ALTER COLUMN "plan" TYPE "public"."subscription_plan"
  USING plan::"public"."subscription_plan";
ALTER TABLE "public"."organization_subscription"
  ALTER COLUMN "plan" SET DEFAULT 'free';
