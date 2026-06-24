-- Modify "user_subscription" table
ALTER TABLE "public"."user_subscription" ADD COLUMN "apple_addon_original_transaction_id" text NULL, ADD COLUMN "apple_addon_product_id" text NULL, ADD CONSTRAINT "user_subscription_apple_addon_original_transaction_id_key" UNIQUE ("apple_addon_original_transaction_id");
-- Create index "idx_user_subscription_apple_addon_original_transaction_id" to table: "user_subscription"
CREATE INDEX "idx_user_subscription_apple_addon_original_transaction_id" ON "public"."user_subscription" ("apple_addon_original_transaction_id") WHERE (apple_addon_original_transaction_id IS NOT NULL);

-- Data migration: flag existing Instagram + WhatsApp twist rows as add-on
-- (premium) connectors, matching PREMIUM_TWIST_PACKAGE_IDS in
-- workers/api/src/twist/premium-connectors.ts. New connector deploys stamp this
-- automatically; this backfills rows already in the DB so their connections are
-- treated as add-on connections immediately. (LinkedIn is already flagged.)
UPDATE "public"."twist" SET "premium" = true
WHERE "twist_package_id" IN (
  'e80fe77e-eeba-4ac5-983a-6f769cff42b9',  -- @plotday/connector-instagram
  '3345727d-7979-4153-8769-e800588cd742'   -- @plotday/connector-whatsapp
);
