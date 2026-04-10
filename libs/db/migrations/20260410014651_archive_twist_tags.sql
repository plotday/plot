-- Create "archive_twist_tags" function
CREATE FUNCTION "public"."archive_twist_tags" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE thread_tag
    SET archived_at = NEW.archived_at
    WHERE actor_id = NEW.id
      AND archived_at IS NULL;

    UPDATE note_tag
    SET archived_at = NEW.archived_at
    WHERE actor_id = NEW.id
      AND archived_at IS NULL;

    RETURN NEW;
END;
$$;
-- Create trigger "archive_twist_tags_on_archive"
CREATE TRIGGER "archive_twist_tags_on_archive" AFTER UPDATE OF "archived_at" ON "public"."priority_twist" FOR EACH ROW WHEN ((old.archived_at IS NULL) AND (new.archived_at IS NOT NULL)) EXECUTE FUNCTION "public"."archive_twist_tags"();

-- Backfill: archive existing tags from already-archived twists
UPDATE thread_tag
SET archived_at = pt.archived_at
FROM priority_twist pt
WHERE thread_tag.actor_id = pt.id
  AND pt.archived_at IS NOT NULL
  AND thread_tag.archived_at IS NULL;

UPDATE note_tag
SET archived_at = pt.archived_at
FROM priority_twist pt
WHERE note_tag.actor_id = pt.id
  AND pt.archived_at IS NOT NULL
  AND note_tag.archived_at IS NULL;
