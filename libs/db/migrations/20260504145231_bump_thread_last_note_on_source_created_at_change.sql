-- Modify "update_thread_last_note_created_at_on_status_change" trigger
CREATE OR REPLACE TRIGGER "update_thread_last_note_created_at_on_status_change" AFTER UPDATE OF "archived_at", "draft", "source_created_at" ON "public"."note" FOR EACH ROW WHEN ((old.draft IS DISTINCT FROM new.draft) OR (old.archived_at IS DISTINCT FROM new.archived_at) OR (old.source_created_at IS DISTINCT FROM new.source_created_at)) EXECUTE FUNCTION "public"."update_thread_on_note_change"();

-- Backfill: recompute last_note_source_created_at for threads whose stored
-- value is behind the actual MAX(note.source_created_at). Before this
-- migration, the trigger only fired on INSERT/DELETE/draft/archived_at
-- changes, so notes whose source_created_at was bumped via upsert (e.g.
-- cancellation notes for Google Calendar events) left a stale value.
UPDATE thread t
SET last_note_source_created_at = m.max_src
FROM (
    SELECT thread_id, MAX(source_created_at) AS max_src
    FROM note
    WHERE draft = FALSE AND archived_at IS NULL
    GROUP BY thread_id
) m
WHERE t.id = m.thread_id
    AND m.max_src IS NOT NULL
    AND (t.last_note_source_created_at IS NULL
        OR t.last_note_source_created_at < m.max_src);
