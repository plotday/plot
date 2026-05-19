-- Modify "priority_team_inherit" function
CREATE OR REPLACE FUNCTION "public"."priority_team_inherit" () RETURNS trigger LANGUAGE plpgsql AS $$
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
