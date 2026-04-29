CREATE TABLE "public"."channel" (
    "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "twist_instance_id" uuid NOT NULL REFERENCES twist_instance (id) ON DELETE CASCADE,
    "channel_id" text NOT NULL,
    "title" text NOT NULL,
    "enabled" boolean NOT NULL DEFAULT false,
    "link_types" jsonb,
    -- LLM-assigned default priority for threads from this channel. Read by
    -- classify_thread_for_user (channel topic short-circuit) after the
    -- user_moved topic check. NULL means "no default; fall back to scoring".
    -- ON DELETE SET NULL so an archived/deleted priority does not cascade to
    -- the channel row; the router re-run on priority-tree change repopulates.
    "default_priority_id" uuid REFERENCES public.priority (id) ON DELETE SET NULL,
    -- LLM rationale for the current default, kept for observability only.
    -- Never read by runtime code; queryable from psql when diagnosing a
    -- routing decision. Overwritten on every router re-run.
    "default_priority_reason" text,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    UNIQUE (twist_instance_id, channel_id)
);

CREATE INDEX idx_channel_seq ON "public"."channel" ("seq");

COMMENT ON TABLE "public"."channel" IS 'Source channels (calendars, projects, etc.) a connector exposes. Each row represents a channel from an external provider that can be enabled for sync. Routing of resulting threads to priorities is per-user via match_priority_for_user.';

COMMENT ON COLUMN "public"."channel"."channel_id" IS 'Provider-specific global ID for the channel. The same calendar/project has the same ID across users.';

CREATE INDEX idx_channel_twist_instance_id ON "public"."channel" ("twist_instance_id");

CREATE TRIGGER set_channel_updated_at
    BEFORE INSERT OR UPDATE ON "public"."channel"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_channel_created_at
    BEFORE INSERT ON "public"."channel"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
