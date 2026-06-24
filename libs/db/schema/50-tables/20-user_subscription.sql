CREATE TABLE "public"."user_subscription" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "stripe_customer_id" text UNIQUE,
    "stripe_subscription_id" text UNIQUE,
    "plan" subscription_plan NOT NULL DEFAULT 'free',
    "status" subscription_status NOT NULL DEFAULT 'active',
    "billing_cycle_start" timestamp with time zone NOT NULL,
    "billing_cycle_end" timestamp with time zone NOT NULL,
    "trial_ends_at" timestamp with time zone,
    -- App Store IAP fields. 'origin' identifies the purchase channel
    -- ('stripe' for web purchases, 'app_store' for StoreKit IAP).
    -- For StoreKit subscriptions, 'apple_original_transaction_id' is the
    -- stable identifier across renewals (the inAppOwnershipType +
    -- originalTransactionId from JWSTransaction). 'apple_product_id'
    -- mirrors the StoreKit product id (e.g. 'day.plot.app.pro_monthly')
    -- so renewals coming through App Store Server Notifications can
    -- update the row without a productId-to-plan lookup table.
    "origin" text NOT NULL DEFAULT 'stripe',
    "apple_original_transaction_id" text UNIQUE,
    "apple_product_id" text,
    -- App Store add-on subscription tracking. Connection add-ons are sold via
    -- a SEPARATE StoreKit subscription group (tiered products addon_1..addon_5,
    -- one active at a time), independent of the plan subscription above. These
    -- track that add-on subscription's lifecycle so its renewals/lapses update
    -- premium_connection_addons without disturbing the plan fields.
    "apple_addon_original_transaction_id" text UNIQUE,
    "apple_addon_product_id" text,
    -- Number of purchased connection add-on credits ($5/mo each). Populated by
    -- Stripe (an add-on line item's quantity on the plan subscription) or by
    -- App Store (the active tiered add-on product → count). The number of
    -- enabled connection add-ons may not exceed this; connection add-ons also
    -- count against the regular connection pool.
    "premium_connection_addons" integer NOT NULL DEFAULT 0,
    UNIQUE(user_id)
);

CREATE INDEX idx_user_subscription_user_id ON "public"."user_subscription" ("user_id");
CREATE INDEX idx_user_subscription_stripe_customer_id ON "public"."user_subscription" ("stripe_customer_id");
CREATE INDEX idx_user_subscription_stripe_subscription_id ON "public"."user_subscription" ("stripe_subscription_id") WHERE "stripe_subscription_id" IS NOT NULL;
CREATE INDEX idx_user_subscription_trial_ends_at ON "public"."user_subscription" ("trial_ends_at") WHERE "trial_ends_at" IS NOT NULL;
CREATE INDEX idx_user_subscription_apple_original_transaction_id ON "public"."user_subscription" ("apple_original_transaction_id") WHERE "apple_original_transaction_id" IS NOT NULL;
CREATE INDEX idx_user_subscription_apple_addon_original_transaction_id ON "public"."user_subscription" ("apple_addon_original_transaction_id") WHERE "apple_addon_original_transaction_id" IS NOT NULL;

CREATE TRIGGER set_user_subscription_updated_at
    BEFORE INSERT OR UPDATE ON "public"."user_subscription"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_user_subscription_created_at
    BEFORE INSERT ON "public"."user_subscription"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
