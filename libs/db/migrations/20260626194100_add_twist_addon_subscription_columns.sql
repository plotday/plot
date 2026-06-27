-- Modify "team_subscription" table
ALTER TABLE "public"."team_subscription" ADD COLUMN "stripe_twist_addon_subscription_id" text NULL, ADD CONSTRAINT "team_subscription_stripe_twist_addon_subscription_id_key" UNIQUE ("stripe_twist_addon_subscription_id");
-- Create index "idx_team_subscription_stripe_twist_addon_subscription_id" to table: "team_subscription"
CREATE INDEX "idx_team_subscription_stripe_twist_addon_subscription_id" ON "public"."team_subscription" ("stripe_twist_addon_subscription_id") WHERE (stripe_twist_addon_subscription_id IS NOT NULL);
-- Modify "user_subscription" table
ALTER TABLE "public"."user_subscription" ADD COLUMN "stripe_twist_addon_subscription_id" text NULL, ADD COLUMN "apple_twist_addon_original_transaction_id" text NULL, ADD COLUMN "apple_twist_addon_product_id" text NULL, ADD CONSTRAINT "user_subscription_stripe_twist_addon_subscription_id_key" UNIQUE ("stripe_twist_addon_subscription_id");
-- Create index "idx_user_subscription_stripe_twist_addon_subscription_id" to table: "user_subscription"
CREATE INDEX "idx_user_subscription_stripe_twist_addon_subscription_id" ON "public"."user_subscription" ("stripe_twist_addon_subscription_id") WHERE (stripe_twist_addon_subscription_id IS NOT NULL);
