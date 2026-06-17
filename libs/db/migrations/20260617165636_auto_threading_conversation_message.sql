-- Create "conversation_message" table
CREATE TABLE "public"."conversation_message" (
  "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
  "twist_id" bigint NOT NULL,
  "conversation_key" text NOT NULL,
  "message_source" text NOT NULL,
  "anchor_source" text NOT NULL,
  "source_created_at" timestamptz NOT NULL,
  "excerpt" text NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("id"),
  CONSTRAINT "conversation_message_twist_id_conversation_key_message_sour_key" UNIQUE ("twist_id", "conversation_key", "message_source")
);
-- Create index "conversation_message_chain_idx" to table: "conversation_message"
CREATE INDEX "conversation_message_chain_idx" ON "public"."conversation_message" ("twist_id", "conversation_key", "source_created_at");
-- Set comment to table: "conversation_message"
COMMENT ON TABLE "public"."conversation_message" IS 'Internal, non-synced, append-only auto-threading assignment log: maps each external message (twist_id, conversation_key, message_source) to its resolved anchor_source (the conversation root). Decided once globally; no FKs by design (see classification_decision).';
