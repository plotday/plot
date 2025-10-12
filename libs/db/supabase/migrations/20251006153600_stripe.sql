CREATE TYPE "public"."subscription_plan" AS enum (
    'free'
);

CREATE TYPE "public"."subscription_status" AS enum (
    'active',
    'canceled',
    'past_due',
    'trialing',
    'incomplete',
    'incomplete_expired',
    'unpaid'
);

CREATE TABLE "public"."user_subscription" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "stripe_customer_id" text,
    "stripe_subscription_id" text,
    "plan" subscription_plan NOT NULL DEFAULT 'free' ::subscription_plan,
    "status" subscription_status NOT NULL DEFAULT 'active' ::subscription_status,
    "billing_cycle_start" timestamp with time zone NOT NULL,
    "billing_cycle_end" timestamp with time zone NOT NULL
);

ALTER TABLE "public"."user_subscription" ENABLE ROW LEVEL SECURITY;

CREATE INDEX idx_user_subscription_stripe_customer_id ON public.user_subscription USING btree (stripe_customer_id);

CREATE INDEX idx_user_subscription_stripe_subscription_id ON public.user_subscription USING btree (stripe_subscription_id)
WHERE (stripe_subscription_id IS NOT NULL);

CREATE INDEX idx_user_subscription_user_id ON public.user_subscription USING btree (user_id);

CREATE UNIQUE INDEX user_subscription_pkey ON public.user_subscription USING btree (id);

CREATE UNIQUE INDEX user_subscription_stripe_customer_id_key ON public.user_subscription USING btree (stripe_customer_id);

CREATE UNIQUE INDEX user_subscription_stripe_subscription_id_key ON public.user_subscription USING btree (stripe_subscription_id);

CREATE UNIQUE INDEX user_subscription_user_id_key ON public.user_subscription USING btree (user_id);

ALTER TABLE "public"."user_subscription"
    ADD CONSTRAINT "user_subscription_pkey" PRIMARY KEY USING INDEX "user_subscription_pkey";

ALTER TABLE "public"."user_subscription"
    ADD CONSTRAINT "user_subscription_stripe_customer_id_key" UNIQUE USING INDEX "user_subscription_stripe_customer_id_key";

ALTER TABLE "public"."user_subscription"
    ADD CONSTRAINT "user_subscription_stripe_subscription_id_key" UNIQUE USING INDEX "user_subscription_stripe_subscription_id_key";

ALTER TABLE "public"."user_subscription"
    ADD CONSTRAINT "user_subscription_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."user_subscription" validate CONSTRAINT "user_subscription_user_id_fkey";

ALTER TABLE "public"."user_subscription"
    ADD CONSTRAINT "user_subscription_user_id_key" UNIQUE USING INDEX "user_subscription_user_id_key";

CREATE POLICY "user_subscription_select_own" ON "public"."user_subscription" AS permissive
    FOR SELECT TO authenticated
        USING ((auth.uid () = user_id));

CREATE TRIGGER set_user_subscription_updated_at
    BEFORE UPDATE ON public.user_subscription
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_agent" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
