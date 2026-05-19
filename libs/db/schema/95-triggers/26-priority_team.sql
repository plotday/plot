-- Inherit team_id from parent on INSERT. If team_id is provided
-- explicitly and disagrees with the parent's team_id, reject.
-- Exception: a direct child of the root (nlevel=2) may be inserted with a
-- non-null team_id when the root has team_id IS NULL — this is the
-- "top-level team priority" promotion path, parallel to the NULL→non-null
-- promotion allowed by priority_team_lock on UPDATE.
CREATE OR REPLACE FUNCTION public.priority_team_inherit ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_parent_team_id bigint;
BEGIN
    -- Root priorities have no parent; whatever was passed stands.
    -- Team membership validation for root inserts is enforced elsewhere
    -- (team_user + the team FK on the column). Only the FK is checked here.
    IF nlevel(NEW.path) <= 1 THEN
        RETURN NEW;
    END IF;
    SELECT team_id INTO v_parent_team_id
    FROM public.priority
    WHERE user_id = NEW.user_id
      AND path = subpath(NEW.path, 0, nlevel(NEW.path) - 1);
    IF NEW.team_id IS NULL THEN
        NEW.team_id := v_parent_team_id;
    ELSIF v_parent_team_id IS NULL AND nlevel(NEW.path) = 2 THEN
        -- NULL → non-null promotion at the top level (direct child of root).
        -- Allowed: the root has no team scope yet, so the child establishes
        -- one for a team subtree. The cascade trigger will NOT propagate
        -- team_id upward; the root stays NULL.
        NULL; -- keep NEW.team_id as provided
    ELSIF NEW.team_id IS DISTINCT FROM v_parent_team_id THEN
        RAISE EXCEPTION 'priority.team_id (%) must match parent team_id (%)',
            NEW.team_id, v_parent_team_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER priority_team_inherit
    BEFORE INSERT ON "public"."priority"
    FOR EACH ROW
    EXECUTE FUNCTION public.priority_team_inherit ();

-- Lock once set non-null, and enforce descendants match parent on UPDATE.
-- Skips the parent-consistency check when the cascade trigger is driving
-- the update (all rows in the same cascade share the same new team_id).
CREATE OR REPLACE FUNCTION public.priority_team_lock ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_parent_team_id bigint;
BEGIN
    IF NEW.team_id IS DISTINCT FROM OLD.team_id THEN
        IF OLD.team_id IS NOT NULL THEN
            RAISE EXCEPTION 'priority.team_id is locked once set';
        END IF;
        -- Skip parent check when this update is driven by the cascade trigger.
        -- Cascade can only produce NULL->non-null transitions (the
        -- lock-once-set RAISE above prevents non-null->anything), so
        -- OLD.team_id IS NULL here. The GUC short-circuits ONLY the
        -- parent-consistency check below.
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

CREATE TRIGGER priority_team_lock
    BEFORE UPDATE ON "public"."priority"
    FOR EACH ROW
    WHEN (OLD.team_id IS DISTINCT FROM NEW.team_id)
    EXECUTE FUNCTION public.priority_team_lock ();

-- Cascade team_id to descendants when a priority's team_id changes
-- (only path: NULL -> non-null, since the lock prevents others).
CREATE OR REPLACE FUNCTION public.priority_team_cascade ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Signal the lock trigger that this update is part of a cascade so it
    -- skips the parent-consistency check (all descendants get the same
    -- team_id in one statement; intermediate parents may not yet reflect the
    -- new value within the same statement snapshot).
    -- The GUC is transaction-local but intentionally broad: any priority
    -- UPDATE between the two set_config calls skips the parent-consistency
    -- check in priority_team_lock. Keep this block atomic — do not add other
    -- priority mutations between the two set_config calls.
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

CREATE TRIGGER priority_team_cascade
    AFTER UPDATE ON "public"."priority"
    FOR EACH ROW
    WHEN (OLD.team_id IS DISTINCT FROM NEW.team_id)
    EXECUTE FUNCTION public.priority_team_cascade ();
