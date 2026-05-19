-- Drop pre-existing functions/triggers if they were created by squashed dev migrations
DROP TRIGGER IF EXISTS "priority_team_inherit" ON "public"."priority";
DROP TRIGGER IF EXISTS "priority_team_cascade" ON "public"."priority";
DROP TRIGGER IF EXISTS "priority_team_lock" ON "public"."priority";
DROP FUNCTION IF EXISTS "public"."priority_team_inherit"();
DROP FUNCTION IF EXISTS "public"."priority_team_cascade"();
DROP FUNCTION IF EXISTS "public"."priority_team_lock"();
-- Create "priority_team_inherit" function
CREATE FUNCTION "public"."priority_team_inherit" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_parent_team_id bigint;
BEGIN
    -- Root priorities have no parent; whatever was passed stands.
    IF nlevel(NEW.path) <= 1 THEN
        RETURN NEW;
    END IF;
    SELECT team_id INTO v_parent_team_id
    FROM public.priority
    WHERE user_id = NEW.user_id
      AND path = subpath(NEW.path, 0, nlevel(NEW.path) - 1);
    IF NEW.team_id IS NULL THEN
        NEW.team_id := v_parent_team_id;
    ELSIF NEW.team_id IS DISTINCT FROM v_parent_team_id THEN
        RAISE EXCEPTION 'priority.team_id (%) must match parent team_id (%)',
            NEW.team_id, v_parent_team_id;
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "priority_team_inherit"
CREATE TRIGGER "priority_team_inherit" BEFORE INSERT ON "public"."priority" FOR EACH ROW EXECUTE FUNCTION "public"."priority_team_inherit"();
-- Create "priority_team_cascade" function
CREATE FUNCTION "public"."priority_team_cascade" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Signal the lock trigger that this update is part of a cascade so it
    -- skips the parent-consistency check (all descendants get the same
    -- team_id in one statement; intermediate parents may not yet reflect the
    -- new value within the same statement snapshot).
    PERFORM set_config('priority_team.cascading', 'on', TRUE);
    UPDATE public.priority
    SET team_id = NEW.team_id
    WHERE user_id = NEW.user_id
      AND path <@ NEW.path
      AND id != NEW.id
      AND team_id IS DISTINCT FROM NEW.team_id;
    PERFORM set_config('priority_team.cascading', 'off', TRUE);
    RETURN NULL;
END;
$$;
-- Create trigger "priority_team_cascade"
CREATE TRIGGER "priority_team_cascade" AFTER UPDATE ON "public"."priority" FOR EACH ROW WHEN (old.team_id IS DISTINCT FROM new.team_id) EXECUTE FUNCTION "public"."priority_team_cascade"();
-- Create "priority_team_lock" function
CREATE FUNCTION "public"."priority_team_lock" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_parent_team_id bigint;
BEGIN
    IF NEW.team_id IS DISTINCT FROM OLD.team_id THEN
        IF OLD.team_id IS NOT NULL THEN
            RAISE EXCEPTION 'priority.team_id is locked once set';
        END IF;
        -- Skip parent check when this update is driven by the cascade trigger.
        IF current_setting('priority_team.cascading', TRUE) = 'on' THEN
            RETURN NEW;
        END IF;
        -- NULL -> non-null promotion: allowed at the top level (parent is root).
        -- For descendants, the parent must already match.
        IF nlevel(NEW.path) > 1 THEN
            SELECT team_id INTO v_parent_team_id
            FROM public.priority
            WHERE user_id = NEW.user_id
              AND path = subpath(NEW.path, 0, nlevel(NEW.path) - 1);
            IF NEW.team_id IS DISTINCT FROM v_parent_team_id THEN
                RAISE EXCEPTION 'descendant priority.team_id must match parent (%); got %',
                    v_parent_team_id, NEW.team_id;
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "priority_team_lock"
CREATE TRIGGER "priority_team_lock" BEFORE UPDATE ON "public"."priority" FOR EACH ROW WHEN (old.team_id IS DISTINCT FROM new.team_id) EXECUTE FUNCTION "public"."priority_team_lock"();
