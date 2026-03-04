-- When Tag.todo (tag_id=1) is added to a note, auto-create a per-user schedule
-- on the note's thread for the actor's user. This makes the thread appear on
-- the user's todo list.
CREATE OR REPLACE FUNCTION propagate_note_tag_todo ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_thread_id uuid;
    v_user_id uuid;
BEGIN
    -- Only handle Tag.todo (tag_id = 1) being added (not archived)
    IF NEW.tag_id != 1 OR NEW.archived_at IS NOT NULL THEN
        RETURN NEW;
    END IF;

    -- For UPDATE, only proceed if the tag was previously archived and is now unarchived
    IF TG_OP = 'UPDATE' AND OLD.archived_at IS NULL THEN
        RETURN NEW;
    END IF;

    -- Get thread_id from the note
    SELECT n.thread_id INTO v_thread_id
    FROM note n
    WHERE n.id = NEW.note_id;

    IF v_thread_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Get user_id from the actor's contact
    SELECT c.user_id INTO v_user_id
    FROM contact c
    WHERE c.id = NEW.actor_id;

    IF v_user_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Insert a per-user schedule (undated = current and ongoing todo)
    -- ON CONFLICT DO NOTHING: don't overwrite if one already exists
    INSERT INTO schedule (thread_id, user_id, "order")
        VALUES (v_thread_id, v_user_id, public.order_first())
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$function$;

CREATE TRIGGER note_tag_todo_propagation
    AFTER INSERT OR UPDATE ON note_tag
    FOR EACH ROW
    EXECUTE FUNCTION propagate_note_tag_todo ();
