-- Modify "priority_team_lock" function
CREATE OR REPLACE FUNCTION "public"."priority_team_lock" () RETURNS trigger LANGUAGE plpgsql AS $$
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
            IF v_parent_team_id IS NULL AND nlevel(NEW.path) = 2 THEN
                -- Top-level promotion: a direct child of the root may be
                -- promoted from NULL to a team_id even when the root has
                -- no team scope. Mirrors the INSERT branch in
                -- priority_team_inherit so an existing user-scoped priority
                -- can be re-tagged as the team's top-level priority.
                NULL;
            ELSIF NEW.team_id IS DISTINCT FROM v_parent_team_id THEN
                RAISE EXCEPTION 'descendant priority.team_id must match parent (%); got %',
                    v_parent_team_id, NEW.team_id;
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
