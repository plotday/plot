CREATE TABLE "public"."team_subscription" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "team_id" bigint NOT NULL REFERENCES team ON DELETE CASCADE,
    "stripe_customer_id" text UNIQUE,
    "stripe_subscription_id" text UNIQUE,
    -- Standalone connection-add-on Stripe subscription (metadata.type='addon'),
    -- SEPARATE from the plan subscription above. Its monthly quantity = the
    -- number of active add-on connections; drives premium_connection_addons.
    "stripe_addon_subscription_id" text UNIQUE,
    -- Standalone twist-add-on Stripe subscription (metadata.type='twist_addon'),
    -- SEPARATE from the plan and connection add-on subscriptions above. Its
    -- monthly quantity = the number of twist add-on blocks; drives twist_addon_count.
    "stripe_twist_addon_subscription_id" text UNIQUE,
    "plan" subscription_plan NOT NULL DEFAULT 'free',
    "status" subscription_status NOT NULL DEFAULT 'active',
    "billing_cycle_start" timestamp with time zone NOT NULL,
    "billing_cycle_end" timestamp with time zone NOT NULL,
    "connection_group_quantity" integer NOT NULL DEFAULT 1,
    -- Number of purchased connection add-on credits ($5/mo each) for the team,
    -- populated by the standalone add-on Stripe subscription's quantity (or,
    -- on Apple, the active tiered add-on product). The number of enabled
    -- connection add-ons may not exceed this. Connection add-ons are billed
    -- separately and do NOT count toward the connection pool.
    "premium_connection_addons" integer NOT NULL DEFAULT 0,
    -- Purchased twist-add-on blocks (each grants +20 automation-capacity slots).
    -- Driven by the standalone twist-add-on subscription (Stripe) / tier (Apple) in B2.
    "twist_addon_count" integer NOT NULL DEFAULT 0,
    UNIQUE (team_id)
);

CREATE INDEX idx_team_subscription_team_id ON "public"."team_subscription" ("team_id");
CREATE INDEX idx_team_subscription_stripe_customer_id ON "public"."team_subscription" ("stripe_customer_id");
CREATE INDEX idx_team_subscription_stripe_subscription_id ON "public"."team_subscription" ("stripe_subscription_id") WHERE "stripe_subscription_id" IS NOT NULL;
CREATE INDEX idx_team_subscription_stripe_addon_subscription_id ON "public"."team_subscription" ("stripe_addon_subscription_id") WHERE "stripe_addon_subscription_id" IS NOT NULL;
CREATE INDEX idx_team_subscription_stripe_twist_addon_subscription_id ON "public"."team_subscription" ("stripe_twist_addon_subscription_id") WHERE "stripe_twist_addon_subscription_id" IS NOT NULL;

CREATE TRIGGER set_team_subscription_updated_at
    BEFORE INSERT OR UPDATE ON "public"."team_subscription"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_team_subscription_created_at
    BEFORE INSERT ON "public"."team_subscription"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
