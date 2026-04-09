CREATE TABLE "public"."note" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "source_created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "author_id" uuid NOT NULL,
    "created_by" uuid NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    "sync_depth" integer,
    "archived_at" timestamp with time zone,
    "thread_id" uuid NOT NULL REFERENCES public.thread ON DELETE CASCADE,
    "draft" boolean NOT NULL DEFAULT FALSE,
    "access_contacts" uuid[],
    "content" text, -- markdown
    "actions" jsonb,
    "key" text,
    "mentions" uuid[],
    "re_note_id" uuid REFERENCES public.note ON DELETE SET NULL,
    "merged_from_thread_id" uuid REFERENCES public.thread ON DELETE SET NULL,
    "embedding" halfvec(384)
);

COMMENT ON COLUMN "public"."note"."source_created_at" IS 'When this note was originally created in its source system (e.g., email sent date, comment creation date). Defaults to now() but can be set by twists. Used for display and sorting. For unread status, use created_at which tracks when the note entered Plot''s database.';

COMMENT ON COLUMN "public"."note"."author_id" IS 'The actor to credit with creating this note. For notes created by users, this is the user''s contact ID (never the user_id). For notes created by twists, this is the twist''s priority_twist_id.';

COMMENT ON COLUMN "public"."note"."created_by" IS 'The user_id or priority_twist_id that actually created this note. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';

COMMENT ON COLUMN "public"."note"."mentions" IS 'Array of priority_twist_ids (twists and connectors) mentioned in this note. Used for dispatch routing only — user visibility is handled by access_contacts.';

COMMENT ON COLUMN "public"."note"."access_contacts" IS 'Restricts note visibility within thread viewers. NULL = all thread viewers can see, empty array = author only, array of contact_ids = author + listed contacts.';

CREATE INDEX idx_note_access_contacts ON "public"."note" USING gin ("access_contacts")
WHERE
    access_contacts IS NOT NULL;

COMMENT ON COLUMN "public"."note"."key" IS 'External identifier for deduplication and sync within a thread. Provided as a top-level field in the Note type. Indexed for efficient lookups. Used with thread_id for upsert behavior, allowing notes to be idempotently created or updated by external key (e.g., "description" for Jira issue descriptions).';

-- Ensure one note per key per thread
-- No WHERE clause needed: NULL != NULL allows multiple notes when key is null
CREATE UNIQUE INDEX note_thread_key_unique ON "public"."note" ("thread_id", "key");

-- Index for efficient key lookups
CREATE INDEX idx_note_key ON "public"."note" ("key")
WHERE
    key IS NOT NULL;

-- Index for FK lookups
CREATE INDEX idx_note_thread_id ON "public"."note" ("thread_id");

-- Index for ordering by created_at within a thread
CREATE INDEX idx_note_created_at ON "public"."note" ("thread_id", "created_at");

-- Support incremental sync queries filtering on updated_at
CREATE INDEX idx_note_updated_at ON "public"."note" ("updated_at");

-- Composite index for common join + filter pattern in user_thread and other views
CREATE INDEX idx_note_thread_archived ON "public"."note" ("thread_id", "archived_at");

-- Support unread calculation filters (n.author_id <> c.id with date comparisons)
-- Enhanced to include created_at for efficient date filtering in unread_check LATERAL join
CREATE INDEX idx_note_author_thread ON "public"."note" ("thread_id", "author_id", "created_at")
WHERE
    archived_at IS NULL;

-- Support lookup of replies to a specific note
CREATE INDEX idx_note_re_note_id ON "public"."note" ("re_note_id")
WHERE
    re_note_id IS NOT NULL;

-- Support mention array queries in user_thread view (mentions @> ARRAY[user_id])
CREATE INDEX idx_note_mentions ON "public"."note" USING gin ("mentions")
WHERE
    mentions IS NOT NULL AND archived_at IS NULL;

CREATE INDEX ON note USING hnsw (embedding halfvec_cosine_ops);

CREATE TRIGGER set_note_updated_at
    BEFORE INSERT OR UPDATE ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_note_created_at
    BEFORE INSERT ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_note_author_and_created_by
    BEFORE INSERT ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION update_author_and_created_by ();

-- Function to update thread's last_note_created_at and thread_read when notes change
CREATE OR REPLACE FUNCTION public.update_thread_on_note_change ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
BEGIN
    -- On addition of a non-draft, non-archived note:
    -- Keep the thread read for the note creator if no one else has added notes
    -- since they last marked it read
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        -- Acquire advisory lock on this thread to serialize concurrent updates
        -- This prevents deadlocks when multiple notes are created simultaneously
        -- Lock is automatically released at transaction end
        PERFORM pg_advisory_xact_lock(hashtext(NEW.thread_id::text));

        -- Update thread's last_note_created_at and last_note_source_created_at when notes are inserted/deleted
        -- Note: note.updated_at changes do NOT trigger this
        -- Uses GREATEST() instead of MAX subquery since we only need to update if the new value exceeds the current
        -- Also update updated_by to the note's updated_by so webhook-originated notes appear in sync views
        UPDATE
            thread
        SET
            last_note_created_at = GREATEST (last_note_created_at, NEW.created_at),
            last_note_source_created_at = GREATEST (last_note_source_created_at, NEW.source_created_at),
            updated_by = NEW.updated_by
        WHERE
            id = NEW.thread_id
            AND (last_note_created_at IS NULL
                OR last_note_created_at < NEW.created_at
                OR last_note_source_created_at IS NULL
                OR last_note_source_created_at < NEW.source_created_at);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$function$;

-- Trigger on note INSERT and DELETE (not UPDATE of content)
CREATE TRIGGER update_thread_last_note_created_at_trigger
    AFTER INSERT OR DELETE ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION update_thread_on_note_change ();

-- Trigger on UPDATE only when draft or archived_at changes
CREATE OR REPLACE TRIGGER update_thread_last_note_created_at_on_status_change
    AFTER UPDATE OF draft,
    archived_at ON "public"."note"
    FOR EACH ROW
    WHEN ((OLD.draft IS DISTINCT FROM NEW.draft OR OLD.archived_at IS DISTINCT FROM NEW.archived_at))
    EXECUTE FUNCTION update_thread_on_note_change ();
