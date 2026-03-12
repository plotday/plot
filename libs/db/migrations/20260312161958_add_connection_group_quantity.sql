-- Modify "organization_subscription" table
ALTER TABLE "public"."organization_subscription" ADD COLUMN "connection_group_quantity" integer NOT NULL DEFAULT 1;
