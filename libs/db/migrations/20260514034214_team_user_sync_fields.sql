-- Modify "team_user" table
ALTER TABLE "public"."team_user" ADD COLUMN "archived_at" timestamptz NULL, ADD COLUMN "seq" xid8 NOT NULL DEFAULT pg_current_xact_id();
-- Create index "idx_team_user_seq" to table: "team_user"
CREATE INDEX "idx_team_user_seq" ON "public"."team_user" ("seq");
-- Create trigger "set_team_user_seq"
CREATE TRIGGER "set_team_user_seq" BEFORE INSERT OR UPDATE ON "public"."team_user" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq"();
-- Modify "priority_team_cascade" function
CREATE OR REPLACE FUNCTION "public"."priority_team_cascade" () RETURNS trigger LANGUAGE plpgsql AS $$
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
    ELSIF NEW.team_id IS DISTINCT FROM v_parent_team_id THEN
        RAISE EXCEPTION 'priority.team_id (%) must match parent team_id (%)',
            NEW.team_id, v_parent_team_id;
    END IF;
    RETURN NEW;
END;
$$;
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
            IF NEW.team_id IS DISTINCT FROM v_parent_team_id THEN
                RAISE EXCEPTION 'descendant priority.team_id must match parent (%); got %',
                    v_parent_team_id, NEW.team_id;
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
