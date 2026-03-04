-- Junction table linking a twist to source channels it wants to observe.
-- When a source creates links in a connected channel, the observing twist
-- receives onLinkCreated/onLinkUpdated/onLinkNoteCreated callbacks.
CREATE TABLE "public"."priority_twist_channel" (
    "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "priority_twist_id" uuid NOT NULL REFERENCES priority_twist (id) ON DELETE CASCADE,
    "source_priority_twist_id" uuid NOT NULL REFERENCES priority_twist (id) ON DELETE CASCADE,
    "channel_id" text NOT NULL,
    "enabled" boolean NOT NULL DEFAULT true,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    UNIQUE (priority_twist_id, source_priority_twist_id, channel_id)
);

CREATE INDEX idx_ptc_priority_twist_id ON priority_twist_channel (priority_twist_id);

CREATE INDEX idx_ptc_source ON priority_twist_channel (source_priority_twist_id, channel_id);
