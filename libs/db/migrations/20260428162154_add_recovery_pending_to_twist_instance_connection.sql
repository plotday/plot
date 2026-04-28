-- Modify "twist_instance_connection" table
ALTER TABLE "public"."twist_instance_connection" ADD COLUMN "recovery_pending" boolean NOT NULL DEFAULT false;
