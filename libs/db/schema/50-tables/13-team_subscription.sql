CREATE TABLE "public"."team_subscription" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "team_id" bigint NOT NULL REFERENCES team ON DELETE CASCADE,
    "stripe_customer_id" text UNIQUE,
    "stripe_subscription_id" text UNIQUE,
    "plan" subscription_plan NOT NULL DEFAULT 'free',
    "status" subscription_status NOT NULL DEFAULT 'active',
    "billing_cycle_start" timestamp with time zone NOT NULL,
    "billing_cycle_end" timestamp with time zone NOT NULL,
    "connection_group_quantity" integer NOT NULL DEFAULT 1,
    UNIQUE (team_id)
);

CREATE INDEX idx_team_subscription_team_id ON "public"."team_subscription" ("team_id");
CREATE INDEX idx_team_subscription_stripe_customer_id ON "public"."team_subscription" ("stripe_customer_id");
CREATE INDEX idx_team_subscription_stripe_subscription_id ON "public"."team_subscription" ("stripe_subscription_id") WHERE "stripe_subscription_id" IS NOT NULL;

CREATE TRIGGER set_team_subscription_updated_at
    BEFORE INSERT OR UPDATE ON "public"."team_subscription"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_team_subscription_created_at
    BEFORE INSERT ON "public"."team_subscription"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
