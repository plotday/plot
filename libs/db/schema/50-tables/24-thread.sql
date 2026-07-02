CREATE TABLE "public"."thread" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL,
    -- The actor to credit with CAUSING this thread's creation. For app
    -- (user-created) threads this is the user's primary contact; for connector
    -- threads, the resolved external author of the originating link; for
    -- non-connection twist threads, the twist_instance. Distinct from
    -- created_by, which is the user_id/twist_instance that performed the
    -- creation action (permissions/callbacks). Set once; never overwritten.
    "author_id" uuid,
    "updated_by" integer NOT NULL DEFAULT 0,
    "archived_at" timestamp with time zone,
    "draft" boolean NOT NULL DEFAULT FALSE,
    "contacts" uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
    -- Contacts who were on this thread but have been dropped from the
    -- active recipient set (subset of `contacts`). Dropped contacts retain
    -- thread visibility (they can still see notes they were on, via
    -- `note.access_contacts`), but are excluded from outbound defaults,
    -- header AvatarGroup, and badge superset on the client.
    --
    -- Invariant: every uuid in dropped_contacts MUST also appear in
    -- contacts. The privileged `update_thread_dropped_contacts` RPC enforces
    -- this. Direct writes to this column bypass the invariant.
    "dropped_contacts" uuid[] DEFAULT ARRAY[]::uuid[],
    "title" text,
    "preview" text,
    "last_note_created_at" timestamp with time zone,
    "sync_depth" integer,
    "last_note_source_created_at" timestamp with time zone,
    "key" text,
    "icon" text,
    -- Thread-level assignee (contact id). Mutable, user-settable, synced.
    -- Mirrors the primary assignment-capable link's assignee for connector
    -- threads (see link-assignee-thread-mirror trigger); Plot-managed otherwise.
    "assignee_id" uuid,
    "groups" uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
    "topic" text,
    "embedding" halfvec(384),
    -- Twist definition that owns this thread's dedup scope. Set by the twist
    -- runtime on creation and never changed afterward. NULL for user-created
    -- threads, which do not participate in cross-user key dedup. FK intentionally
    -- omitted to match link.twist_id and avoid load-order coupling with twist.
    "twist_id" bigint,
    -- The topic (channel) this thread belongs to. ≤1 per thread, giving the
    -- thread a single stable routing string. FK intentionally omitted (mirrors
    -- twist_id) to avoid load-order coupling with the topic table, which is
    -- defined after thread in schema order. Visibility flows through topic
    -- membership (see user_topic_ids); ad-hoc extra recipients still go in
    -- contacts/groups.
    "topic_id" uuid,
    -- Contacts whose own sync attempted to join this thread before being
    -- attested by another user's sync. Promoted into `contacts` when an
    -- attester's upsert includes them. See upsert_thread + file_thread_priority_peers.
    "pending_contacts" uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
    -- Per-contact descriptive metadata, keyed by contact_id. Shape:
    --   { "<contact_uuid>": { "role": "<role_id>", "addedBy": "<user_uuid>" }, ... }
    -- `role` is a LinkTypeConfig.contactRoles[].id declared by the owning
    -- connector (e.g. "to"/"cc"/"bcc" for email, "required"/"optional" for
    -- calendar). Contacts absent from the map are treated as the link
    -- type's default role. `addedBy` is the user who attributed that
    -- contact; used by the API sync layer to gate visibility of hidden
    -- roles (BCC) so only the sender and the contact themselves see them.
    -- Does not affect access control — thread.contacts remains the source
    -- of truth for visibility.
    "contact_meta" jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Server-only (NOT in user.thread): the create_link dispatch spec, stashed
    -- when the user composes a new external item from Plot so a failed send can
    -- be retried. Shape: { twist_instance_id, channel_id, type, status,
    -- invite_emails }. Set at dispatch, cleared once the connector's
    -- onCreateLink succeeds. Recipients are re-resolved from thread.contacts.
    "pending_create_link" jsonb,
    "facets" jsonb,
    -- Scheduled sending: mirrors note.send_at for a thread composed with a
    -- scheduled first note, so the thread shell (title/preview) is invisible
    -- to recipients until release. Set by the client on compose; nulled by
    -- the release sweep together with the note's send_at. NULL = live.
    "send_at" timestamp with time zone,
    -- Monotonic sync cursor (writing transaction's xid8). Maintained by the
    -- update_seq_and_updated_at BEFORE INSERT/UPDATE trigger. Sync queries
    -- gate on `seq < pg_snapshot_xmin(pg_current_snapshot())` to skip rows
    -- from in-flight transactions, eliminating the long-txn cursor-skip race.
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    -- Denormalized GREATEST(note.seq) across non-archived notes on this
    -- thread, maintained by update_thread_on_note_change. Used by user.thread
    -- to project view.seq = GREATEST(thread.seq, last_note_seq, ...) so
    -- note-only changes propagate through the seq cursor.
    "last_note_seq" xid8 NOT NULL DEFAULT '0'::xid8,
    -- When set, this thread is a merge source whose content has been moved
    -- to merged_into_thread_id. The row is archived but its identity columns
    -- (contacts, groups, twist_id, key) are preserved
    -- so SplitThread can restore them. Many sources may point at one target.
    "merged_into_thread_id" uuid REFERENCES public.thread (id) ON DELETE SET NULL,
    -- Team scope. NULL = personal (ungated). Set at creation and locked
    -- thereafter (one-time NULL→value allowed for backfill / promotion).
    -- For connector threads, defaulted from the creating
    -- twist_instance.team_id by set_thread_team_and_external. The team
    -- firewall in user.thread gates visibility on this column.
    "team_id" bigint REFERENCES public.team (id) ON DELETE RESTRICT,
    -- Subset of `contacts` that are NOT subject to the team-membership gate
    -- (non-team "customer" participants). Captured point-in-time when a
    -- contact is added to a team thread: a contact whose linked user is not
    -- a current member of team_id at add-time is recorded here and stays
    -- exempt. Maintained exclusively by set_thread_team_and_external; never
    -- written directly. Always a subset of contacts.
    "external_contacts" uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
    -- Denormalized thread-level feed-ordering base:
    -- GREATEST(last_note_source_created_at, MAX(link.source_created_at),
    -- latest non-recurring schedule end already in the past, created_at).
    -- The per-user feed sort key (thread_priority.activity_at) adds
    -- thread_state.bumped_at on top of this. Maintained by
    -- update_thread_on_note_change (unscoped notes), the link trigger, and the
    -- schedule trigger — all seq-suppressed (see plot.skip_activity_seq).
    -- Nullable for expand-safety; user.thread COALESCEs to created_at. NOT part
    -- of the app's stored shape (the app recomputes ordering locally).
    "activity_base" timestamptz
);

ALTER TABLE "public"."thread"
    ADD CONSTRAINT thread_title_required_when_not_draft CHECK (draft = TRUE OR (title IS NOT NULL AND title != ''));

-- Support common archived_at IS NULL filter in many views
CREATE INDEX idx_thread_archived ON "public"."thread" ("archived_at")
WHERE
    archived_at IS NULL;

-- Support incremental sync queries filtering on updated_at
CREATE INDEX idx_thread_updated_at ON "public"."thread" ("updated_at");

-- Support seq-based incremental sync queries
CREATE INDEX idx_thread_seq ON "public"."thread" ("seq");

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

-- Support twist_instance_thread_update's seq-bounded scan by twist owner.
-- Pattern: WHERE created_by = $1 AND seq >= $2 AND seq < $3.
-- Unconditional (no archived_at filter) because the view returns archived
-- threads so twists learn when their threads are archived.
CREATE INDEX idx_thread_created_by_seq ON "public"."thread" ("created_by", "seq");

COMMENT ON COLUMN "public"."thread"."key" IS 'Identifier for cross-user deduplication within a twist. Scoped by twist_id via thread_twist_key_unique. Not synced to clients.';

-- Ensure one active thread per (twist_id, key). The `archived_at IS NULL`
-- predicate lets a new sync reuse a (twist_id, key) slot once the previous
-- thread has been fully archived (all users archived + no active links).
CREATE UNIQUE INDEX thread_twist_key_unique ON "public"."thread" ("twist_id", "key")
WHERE
    twist_id IS NOT NULL
    AND key IS NOT NULL
    AND archived_at IS NULL;

-- Index for efficient key lookups
CREATE INDEX idx_thread_key ON "public"."thread" ("key")
WHERE
    key IS NOT NULL;

CREATE INDEX idx_thread_contacts ON "public"."thread" USING gin ("contacts");

CREATE INDEX idx_thread_groups ON "public"."thread" USING gin ("groups");

-- NOTE: no index on team_id or a GIN on external_contacts. Both the team
-- firewall checks (a.team_id IS NULL / a.external_contacts && user_contact_ids)
-- run as per-row OR branches inside the user.thread join filter, never as an
-- index probe — both indexes had 0 planner uses in 4 months of prod. Dropped to
-- save write cost on this high-churn table; re-add if a query filters threads by
-- team_id or finds them by external_contacts across the whole table.

CREATE INDEX idx_thread_topic ON "public"."thread" ("topic")
WHERE
    topic IS NOT NULL;

CREATE INDEX idx_thread_topic_id ON "public"."thread" ("topic_id")
WHERE
    topic_id IS NOT NULL;

CREATE INDEX idx_thread_embedding ON "public"."thread" USING hnsw ("embedding" halfvec_cosine_ops);

-- Drives the periodic embedding-reconciliation sweep (scheduled/reconcile-embeddings.ts).
-- The partial WHERE mirrors the sweep's full predicate (not just `embedding IS
-- NULL`) so the index holds ONLY genuinely-pending rows. With only `embedding IS
-- NULL` it also indexed ~36k permanently-ineligible rows (no title / archived),
-- and the planner ignored it entirely in favour of idx_thread_created_at,
-- scanning thousands of dead rows each tick; matched to the query it stays
-- (near) empty, the planner uses it, and the sweep is instant.
CREATE INDEX idx_thread_embedding_pending ON "public"."thread" ("created_at" DESC)
WHERE embedding IS NULL AND title IS NOT NULL AND archived_at IS NULL;

-- Reverse-lookup: list all sources merged into a given target.
CREATE INDEX idx_thread_merged_into ON "public"."thread" ("merged_into_thread_id")
WHERE merged_into_thread_id IS NOT NULL;

-- Trigram index for ILIKE substring search in /sync/threads/search.
CREATE INDEX idx_thread_title_trgm ON "public"."thread" USING gin ("title" extensions.gin_trgm_ops)
WHERE title IS NOT NULL;

COMMENT ON COLUMN "public"."thread"."embedding" IS 'Content embedding (384-dim halfvec) generated at creation from title + initial notes. Used by classify_thread_for_user for content-based priority rule matching.';

COMMENT ON COLUMN "public"."thread"."groups" IS 'Group IDs attached to this thread. Members of referenced groups gain visibility dynamically — new members automatically see past threads.';

COMMENT ON COLUMN "public"."thread"."topic" IS 'Routing key used by classify_thread_for_user. Two conventions: (1) priority:{KEY}[:{SUB_TOPIC}] defaults the thread into the user''s priority with that key when no user_moved example wins; (2) any other string acts as the topic filter over user_moved training examples. On INSERT defaults to, in order: explicit input, or groups[1]::text when unset.';

COMMENT ON COLUMN "public"."thread"."contacts" IS 'Attested contact_ids on this thread. For twist-created threads, a user only gains visibility when their linked contact appears here via another attester''s sync (or via share_thread). Users who attempted to join before attestation land in pending_contacts and are promoted when an attester confirms them. User-created threads do not require attestation.';

COMMENT ON COLUMN "public"."thread"."dropped_contacts" IS 'Contacts who have been dropped from the active recipient set by the message-mode heuristic. Every uuid here MUST also appear in contacts (invariant enforced by update_thread_dropped_contacts). Dropped contacts retain thread visibility but are excluded from outbound defaults and the active-participants display.';

COMMENT ON COLUMN "public"."thread"."twist_id" IS 'Twist definition that created this thread. Scopes (twist_id, key) dedup so all instances of the same twist share the same thread per external item. Immutable after creation.';

COMMENT ON COLUMN "public"."thread"."pending_contacts" IS 'Contacts whose own sync wants to join but who have not yet been attested by another user''s sync. Promoted to contacts (with thread_priority filing) once a subsequent attester includes them.';

COMMENT ON COLUMN "public"."thread"."created_by" IS 'The user_id or twist_instance_id that actually created this thread. Unlike author_id, this always reflects the entity that performed the creation action, used for filtering callbacks and permissions.';

COMMENT ON COLUMN "public"."thread"."author_id" IS 'The actor (contact or twist_instance) credited with causing this thread''s creation. User threads: user''s primary contact. Connector threads: resolved external link author. Non-connection twist threads: the twist_instance. Immutable after first set.';

COMMENT ON COLUMN "public"."thread"."last_note_created_at" IS 'Cached MAX(note.created_at) for non-draft, non-archived notes. Maintained by trigger. Used for unread status in user_thread and user_priority_unread views.';

COMMENT ON COLUMN "public"."thread"."last_note_source_created_at" IS 'Cached MAX(note.source_created_at) for non-draft, non-archived notes. Maintained by trigger. Used for display, sorting, and range_at computation in user_thread view.';

CREATE TRIGGER set_thread_updated_at
    BEFORE INSERT OR UPDATE ON "public"."thread"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_thread_created_at
    BEFORE INSERT ON "public"."thread"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
