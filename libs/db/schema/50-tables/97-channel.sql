CREATE TABLE "public"."channel" (
    "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "twist_instance_id" uuid NOT NULL REFERENCES twist_instance (id) ON DELETE CASCADE,
    "channel_id" text NOT NULL,
    "title" text NOT NULL,
    "enabled" boolean NOT NULL DEFAULT false,
    "link_types" jsonb,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    UNIQUE (twist_instance_id, channel_id)
);

COMMENT ON TABLE "public"."channel" IS 'Source channels (calendars, projects, etc.) a connector exposes. Each row represents a channel from an external provider that can be enabled for sync. Routing of resulting threads to priorities is per-user via match_priority_for_user.';

COMMENT ON COLUMN "public"."channel"."channel_id" IS 'Provider-specific global ID for the channel. The same calendar/project has the same ID across users.';

CREATE INDEX idx_channel_twist_instance_id ON "public"."channel" ("twist_instance_id");

CREATE TRIGGER set_channel_updated_at
    BEFORE INSERT OR UPDATE ON "public"."channel"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_channel_created_at
    BEFORE INSERT ON "public"."channel"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
