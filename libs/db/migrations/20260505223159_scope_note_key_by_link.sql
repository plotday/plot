-- Drop index "note_thread_key_unique" from table: "note"
DROP INDEX "public"."note_thread_key_unique";
-- Modify "note" table
ALTER TABLE "public"."note" ADD COLUMN "link_id" uuid NULL, ADD CONSTRAINT "note_link_id_fkey" FOREIGN KEY ("link_id") REFERENCES "public"."link" ("id") ON UPDATE NO ACTION ON DELETE SET NULL;
-- Create index "idx_note_link_id" to table: "note"
CREATE INDEX "idx_note_link_id" ON "public"."note" ("link_id") WHERE (link_id IS NOT NULL);
-- Create index "note_thread_link_key_unique" to table: "note"
CREATE UNIQUE INDEX "note_thread_link_key_unique" ON "public"."note" ("thread_id", "link_id", "key") WHERE (key IS NOT NULL);
-- Set comment to column: "link_id" on table: "note"
COMMENT ON COLUMN "public"."note"."link_id" IS 'The connector-created link this note belongs to. Scopes note.key uniqueness to (thread_id, link_id, key) so two links on the same thread (e.g. after a merge) can each carry a "description" note. NULL for user/Plot-tool authored notes.';

-- Backfill: for every keyed note created by a connector (twist_instance),
-- assign the earliest matching link on the same thread by the same connector
-- instance. Earliest-link-wins (by created_at, then id) for ambiguous threads
-- with multiple same-connector links. Rare in current data.
WITH candidates AS (
    SELECT
        n.id AS note_id,
        (
            SELECT l.id
            FROM link l
            WHERE l.thread_id = n.thread_id
              AND l.created_by = n.created_by
            ORDER BY l.created_at ASC, l.id ASC
            LIMIT 1
        ) AS link_id
    FROM note n
    JOIN twist_instance ti ON ti.id = n.created_by
    WHERE n.key IS NOT NULL
)
UPDATE note n
SET link_id = c.link_id
FROM candidates c
WHERE n.id = c.note_id
  AND c.link_id IS NOT NULL;

-- Diagnostic: count keyed connector notes that found no matching link.
DO $$
DECLARE
    orphan_count integer;
BEGIN
    SELECT count(*) INTO orphan_count
    FROM note n
    JOIN twist_instance ti ON ti.id = n.created_by
    WHERE n.key IS NOT NULL AND n.link_id IS NULL;
    RAISE NOTICE 'note_link_scoping: % keyed connector notes left without a link_id', orphan_count;
END $$;
