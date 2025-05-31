SET check_function_bodies = OFF;

CREATE OR REPLACE FUNCTION public.handle_priority_x_upsert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    _priority_id uuid;
BEGIN
    _priority_id := NEW.id;
    IF (OLD IS NULL OR NEW.deleted_at IS DISTINCT FROM OLD.deleted_at OR NEW.title IS DISTINCT FROM OLD.title OR NEW.path IS DISTINCT FROM OLD.path OR NEW.draft IS DISTINCT FROM OLD.draft OR NEW.private IS DISTINCT FROM OLD.private OR NEW.pinned IS DISTINCT FROM OLD.pinned OR NEW.do_at IS DISTINCT FROM OLD.do_at OR NEW.done_at IS DISTINCT FROM OLD.done_at OR NEW.order IS DISTINCT FROM OLD.order OR NEW.note IS DISTINCT FROM OLD.note OR NEW.event_series IS DISTINCT FROM OLD.event_series) THEN
        INSERT INTO priority (id, deleted_at, title, path, draft, private, pinned, do_at, done_at, "order", note, event_series)
            VALUES (NEW.id, NEW.deleted_at, NEW.title, NEW.path, NEW.draft, NEW.private, NEW.pinned, NEW.do_at, NEW.done_at, NEW.order, NEW.note, NEW.event_series)
        ON CONFLICT (id)
            DO UPDATE SET
                deleted_at = NEW.deleted_at,
                title = NEW.title,
                path = NEW.path,
                draft = NEW.draft,
                private = NEW.private,
                pinned = NEW.pinned,
                do_at = NEW.do_at,
                done_at = NEW.done_at,
                "order" = NEW.order,
                note = NEW.note,
                event_series = NEW.event_series
            RETURNING
                id INTO _priority_id;
    END IF;
    IF ((OLD IS NULL AND NEW."order" IS NOT NULL) OR (OLD IS NOT NULL AND NEW."order" IS DISTINCT FROM OLD."order")) THEN
        UPDATE
            priority_user
        SET
            "order" = NEW.order
        WHERE
            user_id = COALESCE(auth.uid (), NEW.user_id)
            AND priority_id = _priority_id;
    END IF;
    -- TODO handle path update
    IF ((OLD IS NULL AND (NEW."pomodoro" IS NOT NULL OR NEW."color" IS NOT NULL)) OR (OLD IS NOT NULL AND (NEW."pomodoro" IS DISTINCT FROM OLD."pomodoro" OR NEW."color" IS DISTINCT FROM OLD."color"))) THEN
        INSERT INTO priority_settings (user_id, priority_id, pomodoro, color)
            VALUES (COALESCE(auth.uid (), NEW.user_id), _priority_id, NEW.pomodoro, NEW.color)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                pomodoro = COALESCE(NEW.pomodoro, priority_settings.pomodoro),
                color = COALESCE(NEW.color, priority_settings.color);
    END IF;
    RETURN NEW;
END;
$function$;

