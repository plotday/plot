-- User-defined rules for automatically filing threads into priorities.
-- Rules are channel-scoped and evaluated in precedence order:
--   content > contact_topics > channel
-- Created when users move threads and choose a rule option in the
-- MoveThreadToPriority modal.
CREATE TABLE "public"."priority_rule" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES public."user" (id) ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority (id) ON DELETE CASCADE,
    -- Channel scope: NULL means user-created threads (no connector channel).
    -- FK to channel.id (bigint), NOT channel.channel_id (text).
    "channel_id" bigint REFERENCES public.channel (id) ON DELETE CASCADE,
    -- Rule type determines evaluation logic.
    "type" text NOT NULL CHECK (type IN ('content', 'contact_topics', 'channel')),
    -- For 'content' rules: frozen embedding snapshot from the anchor thread.
    "embedding" halfvec (384),
    -- For 'contact_topics' rules: { "topics": [uuid, ...], "contacts": [uuid, ...] }
    "criteria" jsonb,
    -- Human-readable label for display in the app.
    "label" text,
    -- The anchor thread that inspired this rule (for UI context, not matching).
    "anchor_thread_id" uuid REFERENCES public.thread (id) ON DELETE SET NULL
);

-- Primary lookup: user's rules for a given channel.
CREATE INDEX idx_priority_rule_user_channel
    ON "public"."priority_rule" ("user_id", "channel_id");

-- Reverse lookup: find rules targeting a priority.
CREATE INDEX idx_priority_rule_priority
    ON "public"."priority_rule" ("priority_id");

-- HNSW index for content-rule embedding similarity searches.
CREATE INDEX idx_priority_rule_embedding
    ON "public"."priority_rule" USING hnsw ("embedding" halfvec_cosine_ops);

-- Sync support.
CREATE INDEX idx_priority_rule_updated_at
    ON "public"."priority_rule" ("updated_at");

CREATE TRIGGER set_priority_rule_updated_at
    BEFORE INSERT OR UPDATE ON "public"."priority_rule"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_rule_created_at
    BEFORE INSERT ON "public"."priority_rule"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

COMMENT ON TABLE "public"."priority_rule" IS 'User-defined rules for automatically filing threads into priorities. Rules are channel-scoped and evaluated in precedence order: content > contact_topics > channel.';
COMMENT ON COLUMN "public"."priority_rule"."channel_id" IS 'FK to channel.id (bigint). NULL means this rule applies to user-created threads (no connector). Non-null scopes to threads arriving from that specific channel.';
COMMENT ON COLUMN "public"."priority_rule"."embedding" IS 'Frozen embedding snapshot for content rules. Compared against thread.embedding using cosine similarity with a 0.7 threshold.';
COMMENT ON COLUMN "public"."priority_rule"."criteria" IS 'Match criteria for contact_topics rules. JSON object with optional "topics" (uuid[]) and "contacts" (uuid[]) arrays. Thread matches if it shares any listed topic or contact.';
