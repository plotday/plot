CREATE TABLE "public"."thread" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    "archived_at" timestamp with time zone,
    "draft" boolean NOT NULL DEFAULT FALSE,
    "contacts" uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
    "title" text,
    "preview" text,
    "last_note_created_at" timestamp with time zone,
    "sync_depth" integer,
    "last_note_source_created_at" timestamp with time zone,
    "key" text,
    "icon" text,
    "topics" uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
    "embedding" halfvec(384)
);

ALTER TABLE "public"."thread"
    ADD CONSTRAINT thread_title_required_when_not_draft CHECK (draft = TRUE OR (title IS NOT NULL AND title != ''));

-- Support common archived_at IS NULL filter in many views
CREATE INDEX idx_thread_archived ON "public"."thread" ("archived_at")
WHERE
    archived_at IS NULL;

-- Support incremental sync queries filtering on updated_at
CREATE INDEX idx_thread_updated_at ON "public"."thread" ("updated_at");

-- Index for created_at sorting (critical for pagination queries)
-- Only indexes non-archived threads (most common case)
CREATE INDEX idx_thread_created_at ON "public"."thread" ("created_at" DESC)
WHERE
    archived_at IS NULL;

-- Support twist sync views that filter threads by created_by (twist_instance_id)
-- Used by twist_instance_note_create, twist_instance_thread_update, etc.
CREATE INDEX idx_thread_created_by ON "public"."thread" ("created_by")
WHERE
    archived_at IS NULL;

COMMENT ON COLUMN "public"."thread"."key" IS 'Internal identifier for deduplication within a creator. Used with created_by for upsert behavior. Not synced to clients.';

-- Ensure one thread per key per creator (twist instance or user)
-- NULL != NULL allows multiple threads when key is null
CREATE UNIQUE INDEX thread_created_by_key_unique ON "public"."thread" ("created_by", "key");

-- Index for efficient key lookups
CREATE INDEX idx_thread_key ON "public"."thread" ("key")
WHERE
    key IS NOT NULL;

CREATE INDEX idx_thread_contacts ON "public"."thread" USING gin ("contacts");

CREATE INDEX idx_thread_topics ON "public"."thread" USING gin ("topics");

CREATE INDEX idx_thread_embedding ON "public"."thread" USING hnsw ("embedding" halfvec_cosine_ops);

COMMENT ON COLUMN "public"."thread"."embedding" IS 'Content embedding (384-dim halfvec) generated at creation from title + initial notes. Used by classify_thread_for_user for content-based priority rule matching.';

COMMENT ON COLUMN "public"."thread"."topics" IS 'Topic IDs attached to this thread. Members of referenced topics gain visibility dynamically — new members automatically see past threads.';

COMMENT ON COLUMN "public"."thread"."contacts" IS 'Canonical list of contact_ids with access to this thread, including the author''s primary contact for human-created threads. A user can access the thread if any of their linked (user_contact.linked=true) contacts appears in this array.';

COMMENT ON COLUMN "public"."thread"."created_by" IS 'The user_id or twist_instance_id that actually created this thread. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';

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
