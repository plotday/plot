-- Create "extracted_url_injection" table
CREATE TABLE "public"."extracted_url_injection" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "url_hash" text NOT NULL,
  "thread_id" uuid NOT NULL,
  "priority_id" uuid NOT NULL,
  "requested_by" uuid NOT NULL,
  "status" text NOT NULL DEFAULT 'pending',
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id"),
  CONSTRAINT "extracted_url_injection_thread_url_unique" UNIQUE ("thread_id", "url_hash"),
  CONSTRAINT "extracted_url_injection_status_check" CHECK (status = ANY (ARRAY['pending'::text, 'fulfilled'::text, 'skipped'::text]))
);
-- Create index "extracted_url_injection_status_idx" to table: "extracted_url_injection"
CREATE INDEX "extracted_url_injection_status_idx" ON "public"."extracted_url_injection" ("status");
-- Create index "extracted_url_injection_url_hash_idx" to table: "extracted_url_injection"
CREATE INDEX "extracted_url_injection_url_hash_idx" ON "public"."extracted_url_injection" ("url_hash");
-- Create trigger "set_extracted_url_injection_updated_at"
CREATE TRIGGER "set_extracted_url_injection_updated_at" BEFORE INSERT OR UPDATE ON "public"."extracted_url_injection" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();
