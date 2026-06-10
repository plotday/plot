-- Modify "publisher" table
ALTER TABLE "public"."publisher" ADD COLUMN "can_publish_public" boolean NOT NULL DEFAULT false;

-- Grant Plot's publisher the right to deploy to the public environment.
UPDATE "public"."publisher" SET can_publish_public = true
WHERE lower(name) = 'plot';
