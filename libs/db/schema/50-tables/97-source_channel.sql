CREATE TABLE "public"."source_channel" (
    "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "priority_twist_id" uuid NOT NULL REFERENCES priority_twist (id) ON DELETE CASCADE,
    "channel_id" text NOT NULL,
    "title" text NOT NULL,
    "priority_id" uuid REFERENCES priority (id) ON DELETE SET NULL,
    "enabled" boolean NOT NULL DEFAULT false,
    "create_threads" text NOT NULL DEFAULT 'all',
    "link_types" jsonb,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    UNIQUE (priority_twist_id, channel_id)
);

COMMENT ON TABLE "public"."source_channel" IS 'Maps source channels (calendars, projects, etc.) to priorities. Each row represents a channel from an external provider that can be enabled and routed to a specific priority.';

COMMENT ON COLUMN "public"."source_channel"."channel_id" IS 'Provider-specific global ID for the channel. The same calendar/project has the same ID across users.';

COMMENT ON COLUMN "public"."source_channel"."priority_id" IS 'The priority this channel syncs data to. NULL means the channel is known but not routed to any priority.';

CREATE INDEX idx_source_channel_priority_twist_id ON "public"."source_channel" ("priority_twist_id");

CREATE INDEX idx_source_channel_priority_id ON "public"."source_channel" ("priority_id");

CREATE TRIGGER set_source_channel_updated_at
    BEFORE INSERT OR UPDATE ON "public"."source_channel"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_source_channel_created_at
    BEFORE INSERT ON "public"."source_channel"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
