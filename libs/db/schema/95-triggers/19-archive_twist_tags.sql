-- When a priority_twist is archived, archive all thread_tags and note_tags
-- that were created by that twist (actor_id = priority_twist.id).
CREATE OR REPLACE FUNCTION archive_twist_tags()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $function$
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
$function$;

CREATE TRIGGER archive_twist_tags_on_archive
    AFTER UPDATE OF archived_at ON priority_twist
    FOR EACH ROW
    WHEN (OLD.archived_at IS NULL AND NEW.archived_at IS NOT NULL)
    EXECUTE FUNCTION archive_twist_tags();
