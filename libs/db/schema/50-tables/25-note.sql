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
    "access_groups" uuid[],
    "content" text, -- markdown
    "external_content_hash" text, -- SHA-256 of (contentType + "\n" + content) as last seen by the connector; baseline for sync-in preservation
    "actions" jsonb,
    "cta" jsonb, -- time-sensitive call-to-action {kind, service, code, url}; client shows ephemeral prompt
    "key" text,
    "mentions" uuid[],
    "re_note_id" uuid REFERENCES public.note ON DELETE SET NULL,
    "merged_from_thread_id" uuid REFERENCES public.thread ON DELETE SET NULL,
    "link_id" uuid REFERENCES public.link (id) ON DELETE SET NULL,
    "canonical_source" text,
    "embedding" halfvec(384),
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id()
);

COMMENT ON COLUMN "public"."note"."source_created_at" IS 'When this note was originally created in its source system (e.g., email sent date, comment creation date). Defaults to now() but can be set by twists. Used for display and sorting. For unread status, use created_at which tracks when the note entered Plot''s database.';

COMMENT ON COLUMN "public"."note"."author_id" IS 'The actor to credit with creating this note. For notes created by users, this is the user''s contact ID (never the user_id). For notes created by twists, this is the twist''s twist_instance_id.';

COMMENT ON COLUMN "public"."note"."created_by" IS 'The user_id or twist_instance_id that actually created this note. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';

COMMENT ON COLUMN "public"."note"."mentions" IS 'Array of twist_instance_ids (twists and connectors) mentioned in this note. Used for dispatch routing only — user visibility is handled by access_contacts.';

COMMENT ON COLUMN "public"."note"."access_contacts" IS 'Restricts note visibility within thread viewers. NULL = all thread viewers can see, empty array = author only, array of contact_ids = author + listed contacts.';

CREATE INDEX idx_note_access_contacts ON "public"."note" USING gin ("access_contacts")
WHERE
    access_contacts IS NOT NULL;

COMMENT ON COLUMN "public"."note"."access_groups" IS 'Restricts note visibility within thread viewers via group membership, parallel to access_contacts. NULL = thread-default groups can see, array of group_ids = author + members of listed groups (subset of thread.groups). Combines with access_contacts via OR: a non-author user sees the note iff their contact ids overlap access_contacts (when non-null) OR their group ids overlap access_groups (when non-null). When both are NULL, all thread viewers see it.';

CREATE INDEX idx_note_access_groups ON "public"."note" USING gin ("access_groups")
WHERE
    access_groups IS NOT NULL;

COMMENT ON COLUMN "public"."note"."key" IS 'External identifier for deduplication and sync within a thread. Provided as a top-level field in the Note type. Indexed for efficient lookups. Used with thread_id for upsert behavior, allowing notes to be idempotently created or updated by external key (e.g., "description" for Jira issue descriptions).';

COMMENT ON COLUMN "public"."note"."link_id" IS 'The connector-created link this note was first written through. Informational attribution — note visibility is thread-scoped, not link-scoped. Cross-connection dedup is keyed on canonical_source, not link_id. NULL for user/Plot-tool authored notes.';

COMMENT ON COLUMN "public"."note"."external_content_hash" IS 'SHA-256 hash of the content the connector last saw in the external system, computed over (contentType + "\n" + content). Used by connector sync-in to distinguish "external unchanged" (preserve Plot''s content, which may be formatted markdown) from "external edited" (overwrite with incoming). NULL means no baseline yet. Only set by the twist runtime — clients must not write to this column.';

COMMENT ON COLUMN "public"."note"."canonical_source" IS 'The link.source of the link this note was first written through (copied at note write time by createNote). Drives cross-connection dedup: when two users'' connections of the same external resource each write a note with the same key, the partial unique index on (thread_id, canonical_source, key) collapses them to one row. NULL when no link or the link has no source.';

COMMENT ON COLUMN "public"."note"."cta" IS 'Time-sensitive call-to-action extracted at ingest (OTP code or confirm link): {kind:"otp"|"confirm", service, code, url}. NULL when none. Set by the twist runtime from connector extraction; drives the client''s ephemeral OTP/confirm toast and push.';

-- Ensure one keyed note per (thread, link). Partial: notes with no key
-- (user-authored markdown) are unconstrained. NULL link_id rows coexist
-- because NULL != NULL in unique indexes — orphan keyed notes (link
-- deleted) and any user-authored keyed notes use this allowance.
CREATE UNIQUE INDEX note_thread_link_key_unique
    ON "public"."note" ("thread_id", "link_id", "key")
    WHERE key IS NOT NULL;

-- Cross-connection dedup: one live keyed note per (thread, canonical external
-- resource). Two users'' connections of the same calendar event share
-- link.source (e.g. an iCalUID-based identifier), so their description notes
-- collide on this index and converge to one row. Notes whose link has no source
-- fall through to the per-link index above. Archived rows are excluded so a
-- soft-deleted duplicate never occupies the unique slot (dedup archives extras).
CREATE UNIQUE INDEX note_thread_canonical_key_unique
    ON "public"."note" ("thread_id", "canonical_source", "key")
    WHERE canonical_source IS NOT NULL AND key IS NOT NULL AND archived_at IS NULL;

-- Index for efficient key lookups
CREATE INDEX idx_note_key ON "public"."note" ("key")
WHERE
    key IS NOT NULL;

-- Index for FK lookups by link (used during cascading and migration backfill)
CREATE INDEX idx_note_link_id ON "public"."note" ("link_id")
WHERE
    link_id IS NOT NULL;

-- Index for FK lookups
CREATE INDEX idx_note_thread_id ON "public"."note" ("thread_id");

-- Index for ordering by created_at within a thread
CREATE INDEX idx_note_created_at ON "public"."note" ("thread_id", "created_at");

-- Support incremental sync queries filtering on updated_at
CREATE INDEX idx_note_updated_at ON "public"."note" ("updated_at");

-- Support seq-based incremental sync queries
CREATE INDEX idx_note_seq ON "public"."note" ("seq");

-- Support twist_instance_note_update's seq-bounded scan by twist owner.
-- Pattern: WHERE created_by = $1 AND seq >= $2 AND seq < $3.
CREATE INDEX idx_note_created_by_seq ON "public"."note" ("created_by", "seq");

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

-- Drives the periodic embedding-reconciliation sweep (scheduled/reconcile-embeddings.ts).
-- Partial on `embedding IS NULL` so it indexes only the backlog and shrinks to
-- (near) empty once embeddings are filled in, keeping the recurring sweep cheap.
CREATE INDEX idx_note_embedding_pending ON "public"."note" ("created_at" DESC)
WHERE embedding IS NULL;

-- Trigram index for ILIKE substring search in /sync/threads/search.
-- Partial: search only scans non-archived, non-draft notes, so we can
-- restrict the index to the same rows and keep it dramatically smaller.
CREATE INDEX idx_note_content_trgm ON "public"."note" USING gin ("content" extensions.gin_trgm_ops)
WHERE archived_at IS NULL AND draft = FALSE AND content IS NOT NULL;

CREATE TRIGGER set_note_updated_at
    BEFORE INSERT OR UPDATE ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

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
    -- Only act on visible, non-draft notes.
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        PERFORM pg_advisory_xact_lock(hashtext(NEW.thread_id::text));

        IF NEW.access_contacts IS NULL AND NEW.access_groups IS NULL THEN
            -- UNSCOPED note: everyone who can see the thread can see it.
            -- Bump the shared last_note_* columns exactly as before so the
            -- thread re-emits / re-sorts for all recipients.
            UPDATE thread
            SET last_note_created_at = GREATEST (last_note_created_at, NEW.created_at),
                last_note_source_created_at = GREATEST (last_note_source_created_at, NEW.source_created_at),
                last_note_seq = GREATEST (last_note_seq, NEW.seq),
                updated_by = NEW.updated_by
            WHERE id = NEW.thread_id
              AND (last_note_created_at IS NULL
                  OR last_note_created_at < NEW.created_at
                  OR last_note_source_created_at IS NULL
                  OR last_note_source_created_at < NEW.source_created_at
                  OR last_note_seq < NEW.seq);
        ELSE
            -- SCOPED note: do NOT touch the shared last_note_* columns (that
            -- would re-emit the thread for the whole audience, leaking the
            -- existence of a private reply). Instead bump thread_state for
            -- exactly the users who can see this note, so the thread
            -- re-emits / re-sorts / unreads only for them. The author's row
            -- is bumped but kept read; other visible users get read_at = NULL.
            --
            -- "The author" is identified by NEW.author_id (the contact credited
            -- with the note), resolved to its owning user, NOT only by
            -- NEW.created_by. For a reply the user made OUTSIDE Plot (e.g. in
            -- Gmail) and a connector synced back, created_by is the connector's
            -- twist_instance_id while author_id is the user's own linked
            -- contact — so a created_by-only check would mark the author unread
            -- and notify them about their own reply.
            INSERT INTO thread_state (user_id, thread_id, read_at, bumped_at)
            SELECT v.user_id,
                   NEW.thread_id,
                   CASE
                       WHEN v.user_id = NEW.created_by
                            OR NEW.author_id = ANY("user".user_contact_ids(v.user_id))
                       THEN now()
                       ELSE NULL
                   END,
                   now()
            FROM (
                SELECT tp.user_id
                FROM thread_priority tp
                WHERE tp.thread_id = NEW.thread_id
                  AND tp.revoked_at IS NULL
                  AND (
                      tp.user_id = NEW.created_by
                      OR (NEW.access_contacts IS NOT NULL
                          AND NEW.access_contacts && "user".user_contact_ids(tp.user_id))
                      OR (NEW.access_groups IS NOT NULL
                          AND NEW.access_groups && "user".user_group_ids(tp.user_id))
                  )
            ) v
            ON CONFLICT (user_id, thread_id) DO UPDATE
            SET bumped_at = now(),
                -- A non-author visible user must see the thread as unread
                -- again; never clobber the author's own read state. The author
                -- is matched by NEW.author_id (its owning user) as well as by
                -- created_by, so a reply synced back from an external system
                -- (created_by = connector, author_id = the user's contact)
                -- does not re-surface as unread for its own author.
                read_at = CASE
                    WHEN thread_state.user_id = NEW.created_by
                         OR NEW.author_id = ANY("user".user_contact_ids(thread_state.user_id))
                    THEN thread_state.read_at
                    ELSE NULL
                END,
                updated_at = now();
        END IF;
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$function$;

-- Trigger on note INSERT and DELETE (not UPDATE of content)
CREATE TRIGGER update_thread_last_note_created_at_trigger
    AFTER INSERT OR DELETE ON "public"."note"
    FOR EACH ROW
    EXECUTE FUNCTION update_thread_on_note_change ();

-- Trigger on UPDATE when draft, archived_at, or source_created_at changes.
-- source_created_at is included so cancellation/edit upserts (which keep the
-- same row but bump source_created_at to the new external timestamp) advance
-- thread.last_note_source_created_at — without this, the activity feed shows
-- the original event time instead of the cancellation time for, e.g.,
-- cancelled recurring Google Calendar events.
CREATE OR REPLACE TRIGGER update_thread_last_note_created_at_on_status_change
    AFTER UPDATE OF draft,
    archived_at,
    source_created_at ON "public"."note"
    FOR EACH ROW
    WHEN ((OLD.draft IS DISTINCT FROM NEW.draft
        OR OLD.archived_at IS DISTINCT FROM NEW.archived_at
        OR OLD.source_created_at IS DISTINCT FROM NEW.source_created_at))
    EXECUTE FUNCTION update_thread_on_note_change ();
