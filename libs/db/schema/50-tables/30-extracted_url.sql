-- Global, user-agnostic cache of URL -> extracted Markdown article content.
-- The blob itself lives in R2 (ARTICLES_BUCKET) under "{url_hash}.md"; this
-- table tracks job status and small metadata (title/author/description).
-- Server-only: not exposed via any user.* view and intentionally has no seq
-- or archived_at — clients never sync this directly.
CREATE TABLE "public"."extracted_url" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "url_hash" text UNIQUE NOT NULL,
    "url" text NOT NULL,
    "status" text NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'extracting', 'completed', 'failed')),
    "extractor_version" integer NOT NULL DEFAULT 1,
    "r2_key" text,
    "title" text,
    "author" text,
    "description" text,
    "byte_size" integer,
    "error_code" text,
    "error_message" text,
    "attempts" integer NOT NULL DEFAULT 0,
    "last_attempt_at" timestamp with time zone,
    "extracted_at" timestamp with time zone,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now()
);

CREATE INDEX "extracted_url_status_idx" ON "public"."extracted_url" ("status");

CREATE TRIGGER set_extracted_url_updated_at
    BEFORE INSERT OR UPDATE ON "public"."extracted_url"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
