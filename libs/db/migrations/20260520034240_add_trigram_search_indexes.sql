-- Create extension "pg_trgm"
CREATE EXTENSION "pg_trgm" WITH SCHEMA "extensions" VERSION "1.6";
-- Create index "idx_contact_email_trgm" to table: "contact"
CREATE INDEX "idx_contact_email_trgm" ON "public"."contact" USING GIN ("email" extensions.gin_trgm_ops) WHERE ((archived_at IS NULL) AND (email IS NOT NULL));
-- Create index "idx_contact_name_trgm" to table: "contact"
CREATE INDEX "idx_contact_name_trgm" ON "public"."contact" USING GIN ("name" extensions.gin_trgm_ops) WHERE ((archived_at IS NULL) AND (name IS NOT NULL));
-- Create index "idx_link_preview_trgm" to table: "link"
CREATE INDEX "idx_link_preview_trgm" ON "public"."link" USING GIN ("preview" extensions.gin_trgm_ops) WHERE (preview IS NOT NULL);
-- Create index "idx_link_source_url_trgm" to table: "link"
CREATE INDEX "idx_link_source_url_trgm" ON "public"."link" USING GIN ("source_url" extensions.gin_trgm_ops) WHERE (source_url IS NOT NULL);
-- Create index "idx_link_title_trgm" to table: "link"
CREATE INDEX "idx_link_title_trgm" ON "public"."link" USING GIN ("title" extensions.gin_trgm_ops) WHERE (title IS NOT NULL);
-- Create index "idx_note_content_trgm" to table: "note"
CREATE INDEX "idx_note_content_trgm" ON "public"."note" USING GIN ("content" extensions.gin_trgm_ops) WHERE ((archived_at IS NULL) AND (draft = false) AND (content IS NOT NULL));
-- Create index "idx_thread_title_trgm" to table: "thread"
CREATE INDEX "idx_thread_title_trgm" ON "public"."thread" USING GIN ("title" extensions.gin_trgm_ops) WHERE (title IS NOT NULL);
