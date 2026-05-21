-- Create "extracted_url" table
CREATE TABLE "public"."extracted_url" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "url_hash" text NOT NULL,
  "url" text NOT NULL,
  "status" text NOT NULL DEFAULT 'pending',
  "extractor_version" integer NOT NULL DEFAULT 1,
  "r2_key" text NULL,
  "title" text NULL,
  "author" text NULL,
  "description" text NULL,
  "byte_size" integer NULL,
  "error_code" text NULL,
  "error_message" text NULL,
  "attempts" integer NOT NULL DEFAULT 0,
  "last_attempt_at" timestamptz NULL,
  "extracted_at" timestamptz NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id"),
  CONSTRAINT "extracted_url_url_hash_key" UNIQUE ("url_hash"),
  CONSTRAINT "extracted_url_status_check" CHECK (status = ANY (ARRAY['pending'::text, 'extracting'::text, 'completed'::text, 'failed'::text]))
);
-- Create index "extracted_url_status_idx" to table: "extracted_url"
CREATE INDEX "extracted_url_status_idx" ON "public"."extracted_url" ("status");
-- Create trigger "set_extracted_url_updated_at"
CREATE TRIGGER "set_extracted_url_updated_at" BEFORE INSERT OR UPDATE ON "public"."extracted_url" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
