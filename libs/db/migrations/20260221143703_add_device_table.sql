-- Create "device" table
CREATE TABLE "public"."device" (
  "id" uuid NOT NULL DEFAULT uuidv7(),
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "user_id" uuid NOT NULL,
  "platform" text NOT NULL,
  "push_token" text NOT NULL,
  "app_version" text NULL,
  PRIMARY KEY ("id"),
  CONSTRAINT "device_push_token_key" UNIQUE ("push_token"),
  CONSTRAINT "device_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "device_platform_check" CHECK (platform = ANY (ARRAY['ios'::text, 'android'::text]))
);
-- Create index "idx_device_user_id" to table: "device"
CREATE INDEX "idx_device_user_id" ON "public"."device" ("user_id");
-- Create trigger "set_device_created_at"
CREATE TRIGGER "set_device_created_at" BEFORE INSERT ON "public"."device" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_device_updated_at"
CREATE TRIGGER "set_device_updated_at" BEFORE INSERT OR UPDATE ON "public"."device" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
