-- Junction table linking a twist to source channels it wants to observe.
-- When a source creates links in a connected channel, the observing twist
-- receives onLinkCreated/onLinkUpdated/onLinkNoteCreated callbacks.
CREATE TABLE "public"."twist_instance_channel" (
    "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "twist_instance_id" uuid NOT NULL REFERENCES twist_instance (id) ON DELETE CASCADE,
    "source_twist_instance_id" uuid NOT NULL REFERENCES twist_instance (id) ON DELETE CASCADE,
    "channel_id" text NOT NULL,
    "enabled" boolean NOT NULL DEFAULT true,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    UNIQUE (twist_instance_id, source_twist_instance_id, channel_id)
);

CREATE INDEX idx_twist_instance_channel_instance ON twist_instance_channel (twist_instance_id);

CREATE INDEX idx_twist_instance_channel_source ON twist_instance_channel (source_twist_instance_id, channel_id);
