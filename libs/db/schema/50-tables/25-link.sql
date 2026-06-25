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
    -- related_source (or vice versa) share the same thread.
    -- DEPRECATED: superseded by `sources`. Still populated for one release for
    -- back-compat with readers that haven't migrated yet.
    "related_source" text,
    -- Canonical identifiers for this link. Two links overlap in `sources` share
    -- a thread (array overlap, `sources && new.sources`). Lets any connector
    -- bundle through canonical aliases (e.g. `icaluid:<iCalUID>`) without
    -- depending on another connector's exact source format.
    "sources" text[] NOT NULL DEFAULT '{}',
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
    -- Sticky capability flag: TRUE once this link has carried an assignee.
    -- Set by upsert_link; used by the mirror trigger to identify
    -- assignment-capable links (only such connectors ever set an assignee).
    "supports_assignee" boolean NOT NULL DEFAULT false,
    -- Connector-supplied primary-link ranking. Clients display the highest-
    -- priority non-archived canonical (note_scoped = false) link as the thread's
    -- single external link; ties break on earliest created_at. Default 0.
    "priority" integer NOT NULL DEFAULT 0,
    -- When true, this link is attached to a note (note.link_id), not the thread.
    -- Note-scoped links still participate in source->thread co-location
    -- (sources overlap) but are excluded from thread-level surfacing and
    -- primary-link selection. Set for augmenter content (e.g. Granola).
    "note_scoped" boolean NOT NULL DEFAULT false,
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
    "merged_from_thread_id" uuid REFERENCES public.thread ON DELETE SET NULL,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    -- Soft-delete marker for per-item removals that have no bulk client
    -- signal (archiveLinks with a meta/type/status filter on a live instance
    -- + enabled channel). Delivered to the owner via user.link_redacted.
    -- Bulk removals (uninstall / channel disable) still hard-delete.
    "archived_at" timestamptz
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

-- Ensure one LIVE link per source per priority root. Partial on
-- archived_at IS NULL so a soft-deleted tombstone no longer occupies the
-- slot: re-sync inserts a fresh row (no revival) and the constraint still
-- guarantees a single live link per source (the breadcrumb invariant).
CREATE UNIQUE INDEX link_source_priority_unique ON "public"."link" ("source", "source_priority_root")
WHERE
    archived_at IS NULL;

-- Soft-deleted tombstones (drives user.link_redacted + future GC).
CREATE INDEX idx_link_archived_at ON "public"."link" ("archived_at")
WHERE
    archived_at IS NOT NULL;

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

-- Index for cross-connector thread bundling via related_source (legacy)
CREATE INDEX idx_link_related_source ON "public"."link" ("related_source")
WHERE
    related_source IS NOT NULL;

-- GIN index for sources[] overlap (&&) and contains (@>) lookups
CREATE INDEX idx_link_sources ON "public"."link" USING GIN ("sources");

-- Support incremental sync queries filtering on updated_at
CREATE INDEX idx_link_updated_at ON "public"."link" ("updated_at");

-- Support seq-based incremental sync queries
CREATE INDEX idx_link_seq ON "public"."link" ("seq");

-- Support twist sync views that filter links by created_by (twist_instance_id)
CREATE INDEX idx_link_created_by ON "public"."link" ("created_by");

-- Trigram indexes for ILIKE substring search in /sync/threads/search.
CREATE INDEX idx_link_title_trgm ON "public"."link" USING gin ("title" extensions.gin_trgm_ops)
WHERE title IS NOT NULL;

CREATE INDEX idx_link_source_url_trgm ON "public"."link" USING gin ("source_url" extensions.gin_trgm_ops)
WHERE source_url IS NOT NULL;

CREATE INDEX idx_link_preview_trgm ON "public"."link" USING gin ("preview" extensions.gin_trgm_ops)
WHERE preview IS NOT NULL;

-- Maintain thread.activity_base when a link's source_created_at lands later than
-- the thread's current base (feed ordering includes the latest link time).
-- Seq-suppressed: the app receives link timestamps via /sync/links and recomputes
-- ordering locally, so re-emitting the thread would be redundant sync. The
-- thread_priority.activity_at fan-out is appended once that column exists.
CREATE OR REPLACE FUNCTION public.update_thread_activity_from_link ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
    IF NEW.thread_id IS NOT NULL AND NEW.source_created_at IS NOT NULL THEN
        PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
        -- activity_base is the max of CONTENT source times only — never seeded
        -- with created_at (import time). GREATEST() ignores a NULL activity_base,
        -- so the first link sets it to source_created_at even when that predates
        -- the thread's import. The created_at fallback happens at read time in
        -- thread_priority.activity_at, so backfilled content sorts by its origin.
        UPDATE thread
        SET activity_base = GREATEST(activity_base, NEW.source_created_at)
        WHERE id = NEW.thread_id
          AND (activity_base IS NULL OR activity_base < NEW.source_created_at);
        PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER update_thread_activity_from_link_ins
    AFTER INSERT ON "public"."link"
    FOR EACH ROW
    EXECUTE FUNCTION update_thread_activity_from_link ();

CREATE TRIGGER update_thread_activity_from_link_upd
    AFTER UPDATE OF source_created_at, thread_id ON "public"."link"
    FOR EACH ROW
    WHEN (OLD.source_created_at IS DISTINCT FROM NEW.source_created_at
        OR OLD.thread_id IS DISTINCT FROM NEW.thread_id)
    EXECUTE FUNCTION update_thread_activity_from_link ();

CREATE TRIGGER set_link_updated_at
    BEFORE INSERT OR UPDATE ON "public"."link"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_link_created_at
    BEFORE INSERT ON "public"."link"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
