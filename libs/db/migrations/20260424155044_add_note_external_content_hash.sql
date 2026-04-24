-- Modify "note" table
ALTER TABLE "public"."note" ADD COLUMN "external_content_hash" text NULL;
-- Set comment to column: "external_content_hash" on table: "note"
COMMENT ON COLUMN "public"."note"."external_content_hash" IS 'SHA-256 hash of the content the connector last saw in the external system, computed over (contentType + "\n" + content). Used by connector sync-in to distinguish "external unchanged" (preserve Plot''s content, which may be formatted markdown) from "external edited" (overwrite with incoming). NULL means no baseline yet. Only set by the twist runtime — clients must not write to this column.';
