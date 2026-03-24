-- Create "secure_option" table
CREATE TABLE "public"."secure_option" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "priority_twist_id" uuid NOT NULL,
  "key" text NOT NULL,
  "encrypted_value" text NOT NULL,
  "iv" text NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id"),
  CONSTRAINT "secure_option_priority_twist_id_key_key" UNIQUE ("priority_twist_id", "key"),
  CONSTRAINT "secure_option_priority_twist_id_fkey" FOREIGN KEY ("priority_twist_id") REFERENCES "public"."priority_twist" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_secure_option_pt" to table: "secure_option"
CREATE INDEX "idx_secure_option_pt" ON "public"."secure_option" ("priority_twist_id");
-- Create trigger "set_secure_option_updated_at"
CREATE TRIGGER "set_secure_option_updated_at" BEFORE INSERT OR UPDATE ON "public"."secure_option" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
