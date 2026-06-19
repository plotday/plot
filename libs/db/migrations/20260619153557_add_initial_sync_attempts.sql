-- Modify "twist_instance_connection" table
ALTER TABLE "public"."twist_instance_connection" ADD COLUMN "initial_sync_attempts" integer NOT NULL DEFAULT 0;
