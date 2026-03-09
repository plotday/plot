-- Create enum type "organization_role"
CREATE TYPE "public"."organization_role" AS ENUM ('admin', 'member');
-- Modify "domain" table
ALTER TABLE "public"."domain" ADD COLUMN "auto_join" boolean NOT NULL DEFAULT false;
-- Create trigger "set_organization_updated_at"
CREATE TRIGGER "set_organization_updated_at" BEFORE INSERT OR UPDATE ON "public"."organization" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Modify "organization" table
ALTER TABLE "public"."organization" ADD COLUMN "updated_at" timestamptz NOT NULL DEFAULT now();
-- Create "organization_subscription" table
CREATE TABLE "public"."organization_subscription" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "organization_id" bigint NOT NULL,
  "stripe_customer_id" text NULL,
  "stripe_subscription_id" text NULL,
  "plan" "public"."subscription_plan" NOT NULL DEFAULT 'free',
  "status" "public"."subscription_status" NOT NULL DEFAULT 'active',
  "billing_cycle_start" timestamptz NOT NULL,
  "billing_cycle_end" timestamptz NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "organization_subscription_organization_id_key" UNIQUE ("organization_id"),
  CONSTRAINT "organization_subscription_stripe_customer_id_key" UNIQUE ("stripe_customer_id"),
  CONSTRAINT "organization_subscription_stripe_subscription_id_key" UNIQUE ("stripe_subscription_id"),
  CONSTRAINT "organization_subscription_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organization" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_organization_subscription_organization_id" to table: "organization_subscription"
CREATE INDEX "idx_organization_subscription_organization_id" ON "public"."organization_subscription" ("organization_id");
-- Create index "idx_organization_subscription_stripe_customer_id" to table: "organization_subscription"
CREATE INDEX "idx_organization_subscription_stripe_customer_id" ON "public"."organization_subscription" ("stripe_customer_id");
-- Create index "idx_organization_subscription_stripe_subscription_id" to table: "organization_subscription"
CREATE INDEX "idx_organization_subscription_stripe_subscription_id" ON "public"."organization_subscription" ("stripe_subscription_id") WHERE (stripe_subscription_id IS NOT NULL);
-- Create trigger "set_organization_subscription_created_at"
CREATE TRIGGER "set_organization_subscription_created_at" BEFORE INSERT ON "public"."organization_subscription" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_organization_subscription_updated_at"
CREATE TRIGGER "set_organization_subscription_updated_at" BEFORE INSERT OR UPDATE ON "public"."organization_subscription" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
-- Modify "insert_domain" function
CREATE OR REPLACE FUNCTION "public"."insert_domain" ("email" text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    domain_name text := get_domain (email);
    domain_id bigint;
BEGIN
    SELECT
        id INTO domain_id
    FROM
        public.domain
    WHERE
        "name" = domain_name;
    IF NOT FOUND THEN
        INSERT INTO public.domain ("name")
            VALUES (domain_name)
        RETURNING
            id INTO domain_id;
    END IF;
    RETURN domain_id;
END;
$$;
-- Create "organization_invitation" table
CREATE TABLE "public"."organization_invitation" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "organization_id" bigint NOT NULL,
  "email" text NOT NULL,
  "role" "public"."organization_role" NOT NULL DEFAULT 'member',
  "invited_by" uuid NOT NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "organization_invitation_organization_id_email_key" UNIQUE ("organization_id", "email"),
  CONSTRAINT "organization_invitation_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "organization_invitation_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organization" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "organization_invitation_email_check" CHECK (email = lower(email))
);
-- Create index "idx_organization_invitation_email" to table: "organization_invitation"
CREATE INDEX "idx_organization_invitation_email" ON "public"."organization_invitation" ("email");
-- Create "organization_member" table
CREATE TABLE "public"."organization_member" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "organization_id" bigint NOT NULL,
  "user_id" uuid NOT NULL,
  "role" "public"."organization_role" NOT NULL DEFAULT 'member',
  PRIMARY KEY ("id"),
  CONSTRAINT "organization_member_organization_id_user_id_key" UNIQUE ("organization_id", "user_id"),
  CONSTRAINT "organization_member_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organization" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "organization_member_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_organization_member_organization_id" to table: "organization_member"
CREATE INDEX "idx_organization_member_organization_id" ON "public"."organization_member" ("organization_id");
-- Create index "idx_organization_member_user_id" to table: "organization_member"
CREATE INDEX "idx_organization_member_user_id" ON "public"."organization_member" ("user_id");
