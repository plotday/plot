-- Modify "twist_instance_connection" table
ALTER TABLE "public"."twist_instance_connection" ADD COLUMN "seed_default_channels" boolean NOT NULL DEFAULT false;
