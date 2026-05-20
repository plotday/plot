-- atlas:txmode none

-- Disable statement_timeout for the duration of the index builds. The
-- note.content trigram GIN index in particular is too large to build in
-- the default 30s per-statement budget on production.
SET statement_timeout = 0;

-- Create extension "pg_trgm"
CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "extensions" VERSION "1.6";

-- Trigram indexes for ILIKE substring search in /sync/threads/search.
--
-- CREATE INDEX CONCURRENTLY runs without holding an AccessExclusiveLock so
-- writes to these tables aren't blocked during the build. CONCURRENTLY
-- cannot run inside a transaction block, hence atlas:txmode none above.
-- IF NOT EXISTS keeps the migration idempotent if a previous attempt
-- partially completed.
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_contact_email_trgm" ON "public"."contact" USING GIN ("email" extensions.gin_trgm_ops) WHERE ((archived_at IS NULL) AND (email IS NOT NULL));
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_contact_name_trgm" ON "public"."contact" USING GIN ("name" extensions.gin_trgm_ops) WHERE ((archived_at IS NULL) AND (name IS NOT NULL));
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_link_preview_trgm" ON "public"."link" USING GIN ("preview" extensions.gin_trgm_ops) WHERE (preview IS NOT NULL);
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_link_source_url_trgm" ON "public"."link" USING GIN ("source_url" extensions.gin_trgm_ops) WHERE (source_url IS NOT NULL);
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_link_title_trgm" ON "public"."link" USING GIN ("title" extensions.gin_trgm_ops) WHERE (title IS NOT NULL);
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_note_content_trgm" ON "public"."note" USING GIN ("content" extensions.gin_trgm_ops) WHERE ((archived_at IS NULL) AND (draft = false) AND (content IS NOT NULL));
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_thread_title_trgm" ON "public"."thread" USING GIN ("title" extensions.gin_trgm_ops) WHERE (title IS NOT NULL);
