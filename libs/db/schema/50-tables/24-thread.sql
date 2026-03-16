CREATE TABLE "public"."thread" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    "archived_at" timestamp with time zone,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "title" text,
    "preview" text,
    "last_note_created_at" timestamp with time zone,
    "sync_depth" integer,
    "last_note_source_created_at" timestamp with time zone,
    "key" text,
    "icon" text
);

ALTER TABLE "public"."thread"
    ADD CONSTRAINT thread_title_required_when_not_draft CHECK (draft = TRUE OR (title IS NOT NULL AND title != ''));

CREATE INDEX idx_thread_priority_id ON "public"."thread" ("priority_id");

-- Support common archived_at IS NULL filter in many views
CREATE INDEX idx_thread_archived ON "public"."thread" ("archived_at")
WHERE
    archived_at IS NULL;

-- Speed up joins from priority to non-archived threads
CREATE INDEX idx_thread_priority_archived ON "public"."thread" ("priority_id", "archived_at");

-- Support incremental sync queries filtering on updated_at
CREATE INDEX idx_thread_updated_at ON "public"."thread" ("updated_at");

-- Index for created_at sorting (critical for pagination queries)
-- Includes priority_id to support common WHERE clauses
-- Only indexes non-archived threads (most common case)
CREATE INDEX idx_thread_created_at_priority ON "public"."thread" ("created_at" DESC, "priority_id")
WHERE
    archived_at IS NULL;

-- Optimized for user_thread and user_priority_unread views
-- Supports efficient filtering and aggregation on last_note_created_at
CREATE INDEX idx_thread_priority_archived_last_note ON "public"."thread" ("priority_id", "last_note_created_at", "created_at")
WHERE
    archived_at IS NULL;

-- Support twist sync views that filter threads by created_by (priority_twist_id)
-- Used by priority_twist_note_create, priority_twist_thread_update, etc.
CREATE INDEX idx_thread_created_by ON "public"."thread" ("created_by")
WHERE
    archived_at IS NULL;

COMMENT ON COLUMN "public"."thread"."key" IS 'Internal identifier for deduplication within a priority. Used with priority_id for upsert behavior. Not synced to clients.';

-- Ensure one thread per key per priority
-- NULL != NULL allows multiple threads when key is null
CREATE UNIQUE INDEX thread_priority_key_unique ON "public"."thread" ("priority_id", "key");

-- Index for efficient key lookups
CREATE INDEX idx_thread_key ON "public"."thread" ("key")
WHERE
    key IS NOT NULL;

COMMENT ON COLUMN "public"."thread"."created_by" IS 'The user_id or priority_twist_id that actually created this thread. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';

COMMENT ON COLUMN "public"."thread"."last_note_created_at" IS 'Cached MAX(note.created_at) for non-draft, non-archived notes. Maintained by trigger. Used for unread status in user_thread and user_priority_unread views.';

COMMENT ON COLUMN "public"."thread"."last_note_source_created_at" IS 'Cached MAX(note.source_created_at) for non-draft, non-archived notes. Maintained by trigger. Used for display, sorting, and range_at computation in user_thread view.';

CREATE TRIGGER set_thread_updated_at
    BEFORE INSERT OR UPDATE ON "public"."thread"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_thread_created_at
    BEFORE INSERT ON "public"."thread"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
