-- Modify "user" table
ALTER TABLE "public"."user" ADD COLUMN "deletion_requested_at" timestamptz NULL;
