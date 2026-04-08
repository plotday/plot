-- Modify "user_subscription" table
ALTER TABLE "public"."user_subscription" ADD COLUMN "trial_ends_at" timestamptz NULL;
-- Create index "idx_user_subscription_trial_ends_at" to table: "user_subscription"
CREATE INDEX "idx_user_subscription_trial_ends_at" ON "public"."user_subscription" ("trial_ends_at") WHERE (trial_ends_at IS NOT NULL);
