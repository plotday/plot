-- Set comment to column: "auto_maintained" on table: "topic"
COMMENT ON COLUMN "public"."topic"."auto_maintained" IS 'TRUE for system-managed topics (Plot Updates). Membership composition is maintained by triggers and cannot be modified via API.';
-- Set comment to column: "key" on table: "topic"
COMMENT ON COLUMN "public"."topic"."key" IS 'Stable identifier for system-managed topics (e.g. ''@plot.updates''). Nullable; user-created topics have no key.';
