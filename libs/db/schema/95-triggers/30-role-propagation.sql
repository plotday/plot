-- Follow-if-matching propagation for focus colour + notifications.
--
-- A focus stores concrete values. It "follows" its role while its value still
-- equals the role's value (value-equality, IS NOT DISTINCT FROM). When the role
-- changes, focuses that still match the OLD role value adopt the NEW value;
-- overridden focuses keep theirs. The role's Inbox always follows the role.
--
-- These UPDATEs on priority fire set_priority_updated_at, bumping priority.seq,
-- so clients resync the propagated values.

-- (a) Role colour / notification change -> matching focuses follow.
CREATE OR REPLACE FUNCTION public.propagate_role_to_focuses ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.color IS DISTINCT FROM OLD.color THEN
        UPDATE priority
        SET color = NEW.color
        WHERE role_id = NEW.id
          AND archived_at IS NULL
          AND (is_inbox OR color IS NOT DISTINCT FROM OLD.color);
    END IF;

    IF NEW.early_notifications_enabled IS DISTINCT FROM OLD.early_notifications_enabled
        OR NEW.notify_window IS DISTINCT FROM OLD.notify_window
        OR NEW.see_within IS DISTINCT FROM OLD.see_within THEN
        UPDATE priority
        SET early_notifications_enabled = NEW.early_notifications_enabled,
            notify_window = NEW.notify_window,
            see_within = NEW.see_within
        WHERE role_id = NEW.id
          AND archived_at IS NULL
          AND (is_inbox OR (
              early_notifications_enabled IS NOT DISTINCT FROM OLD.early_notifications_enabled
              AND notify_window IS NOT DISTINCT FROM OLD.notify_window
              AND see_within IS NOT DISTINCT FROM OLD.see_within));
    END IF;

    -- send_window follows independently of the notification trio, so a focus
    -- that overrode notifications still follows the role's send window (and
    -- vice versa).
    IF NEW.send_window IS DISTINCT FROM OLD.send_window THEN
        UPDATE priority
        SET send_window = NEW.send_window
        WHERE role_id = NEW.id
          AND archived_at IS NULL
          AND (is_inbox OR send_window IS NOT DISTINCT FROM OLD.send_window);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER propagate_role_to_focuses
    AFTER UPDATE ON public.role
    FOR EACH ROW
    EXECUTE FUNCTION public.propagate_role_to_focuses ();

-- (b) Focus reassigned to a new role -> per-dimension follow-if-matching.
-- Compares the INCOMING focus value to the OLD role: if it matched (was
-- following), adopt the NEW role's value; otherwise keep the override. This
-- also makes the modal's "change role" case correct when the user changes the
-- colour and the role in the same write.
CREATE OR REPLACE FUNCTION public.apply_role_change_to_focus ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    old_role public.role%ROWTYPE;
    new_role public.role%ROWTYPE;
BEGIN
    IF NEW.role_id IS NOT DISTINCT FROM OLD.role_id THEN
        RETURN NEW;
    END IF;
    IF NEW.role_id IS NULL THEN
        RETURN NEW;  -- focus cleared of its role; nothing to follow
    END IF;
    SELECT * INTO new_role FROM public.role WHERE id = NEW.role_id;
    IF new_role.id IS NULL THEN
        RETURN NEW;  -- dangling role_id; leave the focus's values as-is
    END IF;
    -- old_role is a NULL/zero row when OLD.role_id IS NULL (a focus getting its
    -- first role). Then `NEW.x IS NOT DISTINCT FROM old_role.x` is true only when
    -- NEW.x is NULL, so a value-less focus adopts the new role while a
    -- concrete-valued focus keeps its value as an override — the intended rule.
    SELECT * INTO old_role FROM public.role WHERE id = OLD.role_id;

    -- The Inbox always follows its (new) role.
    IF NEW.is_inbox THEN
        NEW.color := new_role.color;
        NEW.early_notifications_enabled := new_role.early_notifications_enabled;
        NEW.notify_window := new_role.notify_window;
        NEW.see_within := new_role.see_within;
        NEW.send_window := new_role.send_window;
        RETURN NEW;
    END IF;

    IF NEW.color IS NOT DISTINCT FROM old_role.color THEN
        NEW.color := new_role.color;
    END IF;

    IF NEW.early_notifications_enabled IS NOT DISTINCT FROM old_role.early_notifications_enabled
        AND NEW.notify_window IS NOT DISTINCT FROM old_role.notify_window
        AND NEW.see_within IS NOT DISTINCT FROM old_role.see_within THEN
        NEW.early_notifications_enabled := new_role.early_notifications_enabled;
        NEW.notify_window := new_role.notify_window;
        NEW.see_within := new_role.see_within;
    END IF;

    -- send_window follows independently (mirrors propagate_role_to_focuses).
    IF NEW.send_window IS NOT DISTINCT FROM old_role.send_window THEN
        NEW.send_window := new_role.send_window;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER apply_role_change_to_focus
    BEFORE UPDATE OF role_id ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION public.apply_role_change_to_focus ();
