-- Modify "extracted_url" table
ALTER TABLE "public"."extracted_url" DROP CONSTRAINT "extracted_url_status_check", ADD CONSTRAINT "extracted_url_status_check" CHECK (status = ANY (ARRAY['pending'::text, 'extracting'::text, 'completed'::text, 'failed'::text, 'auth_required'::text, 'paywalled'::text]));
