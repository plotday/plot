-- Per-user emoji reactions on threads.
-- Mirror of note_reaction; see that file's header for the emoji
-- column's semantics. `occurrence` is kept for parity with
-- thread_tag (dated event occurrences).
CREATE TABLE "public"."thread_reaction" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "actor_id" uuid NOT NULL,
    "thread_id" uuid NOT NULL REFERENCES thread ON DELETE CASCADE,
    "occurrence" text,
    "emoji" text NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    "sync_depth" integer,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    UNIQUE NULLS NOT DISTINCT ("actor_id", "thread_id", "occurrence", "emoji")
);

COMMENT ON COLUMN "public"."thread_reaction"."occurrence" IS 'Original occurrence date/datetime in text format. For dates: YYYY-MM-DD, for datetimes: YYYY-MM-DDTHH:MM';

CREATE INDEX idx_thread_reaction_thread_id ON "public"."thread_reaction" (thread_id, emoji)
WHERE
    archived_at IS NULL;

CREATE INDEX idx_thread_reaction_thread_id_all ON "public"."thread_reaction" (thread_id);

CREATE INDEX idx_thread_reaction_seq ON "public"."thread_reaction" ("seq");

CREATE TRIGGER set_thread_reaction_updated_at
    BEFORE INSERT OR UPDATE ON "public"."thread_reaction"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();
