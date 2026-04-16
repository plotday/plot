CREATE TABLE "public"."link" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "thread_id" uuid REFERENCES public.thread (id) ON DELETE CASCADE,
    -- Priority for threadless links (links synced without creating threads)
    "priority_id" uuid REFERENCES public.priority (id) ON DELETE CASCADE,
    -- External source identifier for dedup/upsert
    "source" text,
    "source_created_at" timestamp with time zone NOT NULL DEFAULT now(),
    -- Root of the priority path, set by trigger when source is non-null
    "source_priority_root" ltree,
    -- Cross-connector thread bundling: links with source matching another link's
    -- related_source (or vice versa) share the same thread
    "related_source" text,
    -- Actor ID to credit with creating this link
    "author_id" uuid,
    -- Twist definition ID (twist.id) that created this link
    "twist_id" bigint,
    -- User ID or twist_instance_id that created this link
    "created_by" uuid,
    -- Sync tracking
    "updated_by" integer NOT NULL DEFAULT 0,
    "sync_depth" integer,
    -- Display fields
    "title" text,
    "preview" text,
    -- Assignment
    "assignee_id" uuid,
    -- Source-defined type and status (free text)
    "type" text,
    "status" text,
    -- Interactive buttons
    "actions" jsonb,
    -- Source metadata
    "meta" jsonb,
    -- URL to open the original item in its source application
    "source_url" text,
    -- Logo/favicon URL for this link
    "logo" text,
    -- Provider-specific channel ID, matches channel.channel_id
    "channel_id" text,
    "merged_from_thread_id" uuid REFERENCES public.thread ON DELETE SET NULL
);

COMMENT ON COLUMN "public"."link"."source" IS 'External source identifier for deduplication and sync. Used with source_priority_root for upsert behavior.';

COMMENT ON COLUMN "public"."link"."source_created_at" IS 'When this link was originally created in its source system. Defaults to now() but can be set by twists.';

COMMENT ON COLUMN "public"."link"."source_priority_root" IS 'Root element of the priority path. Set by trigger when source is non-null. Used with source to ensure uniqueness per top-level priority.';

COMMENT ON COLUMN "public"."link"."related_source" IS 'Cross-connector thread bundling key. Links whose source matches another link''s related_source share a thread, regardless of creation order.';

COMMENT ON COLUMN "public"."link"."author_id" IS 'The actor to credit with creating this link. For links created by twists on behalf of contacts or users, this is the contact/user.';

COMMENT ON COLUMN "public"."link"."twist_id" IS 'The twist definition ID (twist.id) that created this link. Null for user-created links.';

COMMENT ON COLUMN "public"."link"."created_by" IS 'The user_id or twist_instance_id that actually created this link. Used for filtering callbacks and permissions.';


COMMENT ON COLUMN "public"."link"."type" IS 'Source-defined type string (e.g., issue, pull_request, email, event). Free text, with structured registry in source linkTypes config.';

COMMENT ON COLUMN "public"."link"."status" IS 'Source-defined status string (e.g., open, done, closed). Free text.';

-- Ensure one link per source per priority root
-- No WHERE clause needed: NULL != NULL allows multiple rows when source is null
CREATE UNIQUE INDEX link_source_priority_unique ON "public"."link" ("source", "source_priority_root");

-- Index for efficient source lookups
CREATE INDEX idx_link_source ON "public"."link" ("source")
WHERE
    source IS NOT NULL;

-- Index for thread_id FK lookups
CREATE INDEX idx_link_thread_id ON "public"."link" ("thread_id");

-- Index for priority_id FK lookups (threadless links)
CREATE INDEX idx_link_priority_id ON "public"."link" ("priority_id")
WHERE
    priority_id IS NOT NULL;

-- Index for cross-connector thread bundling via related_source
CREATE INDEX idx_link_related_source ON "public"."link" ("related_source")
WHERE
    related_source IS NOT NULL;

-- Support incremental sync queries filtering on updated_at
CREATE INDEX idx_link_updated_at ON "public"."link" ("updated_at");

-- Support twist sync views that filter links by created_by (twist_instance_id)
CREATE INDEX idx_link_created_by ON "public"."link" ("created_by");

CREATE TRIGGER set_link_updated_at
    BEFORE INSERT OR UPDATE ON "public"."link"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_link_created_at
    BEFORE INSERT ON "public"."link"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
