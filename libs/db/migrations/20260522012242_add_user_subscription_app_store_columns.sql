-- Modify "user_subscription" table
ALTER TABLE "public"."user_subscription" ADD COLUMN "origin" text NOT NULL DEFAULT 'stripe', ADD COLUMN "apple_original_transaction_id" text NULL, ADD COLUMN "apple_product_id" text NULL, ADD CONSTRAINT "user_subscription_apple_original_transaction_id_key" UNIQUE ("apple_original_transaction_id");
-- Create index "idx_user_subscription_apple_original_transaction_id" to table: "user_subscription"
CREATE INDEX "idx_user_subscription_apple_original_transaction_id" ON "public"."user_subscription" ("apple_original_transaction_id") WHERE (apple_original_transaction_id IS NOT NULL);
