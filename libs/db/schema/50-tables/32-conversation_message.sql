-- Internal, append-only assignment log for connector auto-threading.
-- One row per external message that an opted-in connector processed through
-- the sequential fold-or-new resolver. Records the message's resolved
-- "anchor" — the canonical source of the conversation's root thread. A
-- message that starts a conversation is its own anchor; a continuation
-- inherits the previous message's anchor (transitively the conversation
-- root).
--
-- Decided ONCE, globally: keyed by the connector DEFINITION (twist_id) +
-- conversation_key (the connector's channel id) + message_source, so the
-- same external message processed by multiple users' connectors (and every
-- re-sync) reuses the first-processor's decision. This is what makes the
-- decide-at-ingest fold deterministic and identical across users without any
-- visible thread merge or note move.
--
-- Deliberately has NO foreign keys (mirrors classification_decision): writes
-- occur inside the saveLink -> createLink path alongside thread /
-- thread_priority writes, so coupling a lock here would risk the documented
-- thread/thread_priority deadlock. Rows are cheap to outlive their referents.
-- Not synced — no user.* view reads this table.
CREATE TABLE "public"."conversation_message" (
    "id" bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Connector DEFINITION id (twist.id), NOT the per-user instance — the
    -- decision is global across every user of the connector.
    "twist_id" bigint NOT NULL,
    -- The grouping the sequential chain runs within (the connector's
    -- channel_id). DMs and each channel are independent chains.
    "conversation_key" text NOT NULL,
    -- Canonical source of this message (matches the link's primary source).
    "message_source" text NOT NULL,
    -- Resolved anchor: the conversation root's canonical source. Equal to
    -- message_source when this message starts a new thread.
    "anchor_source" text NOT NULL,
    -- External creation time; orders the chain and locates the "previous"
    -- message when resolving a new one.
    "source_created_at" timestamptz NOT NULL,
    -- Short text snippet of this message, reused as the "previous message"
    -- (and, on an anchor row, the conversation-opening) context for the
    -- continuation LLM check. Avoids a join back to note/link.
    "excerpt" text,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    -- One decision per (connector, conversation, message): the upsert key
    -- that makes concurrent first-processors converge on a single anchor.
    UNIQUE ("twist_id", "conversation_key", "message_source")
);

COMMENT ON TABLE "public"."conversation_message" IS 'Internal, non-synced, append-only auto-threading assignment log: maps each external message (twist_id, conversation_key, message_source) to its resolved anchor_source (the conversation root). Decided once globally; no FKs by design (see classification_decision).';

-- Locate the most recent already-assigned message in a conversation (the
-- "previous" message) when resolving a new one: ORDER BY source_created_at
-- DESC within (twist_id, conversation_key).
CREATE INDEX conversation_message_chain_idx
    ON "public"."conversation_message" ("twist_id", "conversation_key", "source_created_at");
