-- Per-user emoji reactions on notes.
--
-- Parallel to note_tag's count-tag range (tag_id >= 1000) but stores the
-- emoji as a Unicode grapheme cluster (e.g. '👍', '👨‍👩‍👧') or, for
-- workspace-custom emoji, a provider-scoped ref like
-- 'slack:T0123ABC/party_parrot'. The discriminator is a prefix match
-- on a recognized provider; everything else is treated as Unicode.
--
-- Ownership rule (enforced in user.upsert_note_reaction /
-- user.update_note_reactions): a user can only add/remove their own
-- reactions. Linked-contact siblings (user.sibling_contact_ids) count
-- as self.
CREATE TABLE "public"."note_reaction" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "actor_id" uuid NOT NULL,
    "note_id" uuid NOT NULL REFERENCES note ON DELETE CASCADE,
    "emoji" text NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    "sync_depth" integer,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    UNIQUE NULLS NOT DISTINCT ("actor_id", "note_id", "emoji")
);

CREATE INDEX idx_note_reaction_note_id ON "public"."note_reaction" (note_id, emoji)
WHERE
    archived_at IS NULL;

-- Full index on note_id to support GROUP BY aggregation in the
-- note_reactions view (which aggregates ALL rows including archived).
CREATE INDEX idx_note_reaction_note_id_full ON "public"."note_reaction" ("note_id");

CREATE INDEX idx_note_reaction_seq ON "public"."note_reaction" ("seq");

CREATE TRIGGER set_note_reaction_updated_at
    BEFORE INSERT OR UPDATE ON "public"."note_reaction"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();
