-- AFTER INSERT (or UN-archive) on team_user: ensure the user has a
-- top-level priority for this team. Path uses generate_path() to produce
-- a random unique segment, matching the convention used in
-- activate_invited_user and ensure_twist_dev_priority.
CREATE OR REPLACE FUNCTION public.team_user_ensure_team_priority ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_root_path ltree;
    v_team_name text;
    v_existing_count int;
BEGIN
    -- Only fire when membership becomes active.
    IF NEW.archived_at IS NOT NULL THEN
        RETURN NULL;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.archived_at IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT path INTO v_root_path
    FROM public.priority
    WHERE user_id = NEW.user_id AND nlevel(path) = 1
    LIMIT 1;
    IF v_root_path IS NULL THEN
        RAISE EXCEPTION 'user % has no root priority', NEW.user_id;
    END IF;

    SELECT name INTO v_team_name FROM public.team WHERE id = NEW.team_id;

    -- If the user already has any non-archived top-level priority with
    -- this team_id, skip (rejoin case where the priority survived).
    SELECT count(*) INTO v_existing_count
    FROM public.priority
    WHERE user_id = NEW.user_id
      AND team_id = NEW.team_id
      AND nlevel(path) = 2
      AND archived_at IS NULL;
    IF v_existing_count > 0 THEN
        RETURN NULL;
    END IF;

    -- generate_path(NULL) produces a random 12-char alphanumeric label,
    -- matching the convention used in activate_invited_user and
    -- ensure_twist_dev_priority.
    INSERT INTO public.priority (created_by, user_id, title, path, team_id)
    VALUES (
        NEW.user_id,
        NEW.user_id,
        v_team_name,
        v_root_path || generate_path(NULL),
        NEW.team_id
    );

    RETURN NULL;
END;
$$;

CREATE TRIGGER team_user_ensure_team_priority
    AFTER INSERT OR UPDATE ON "public"."team_user"
    FOR EACH ROW
    EXECUTE FUNCTION public.team_user_ensure_team_priority ();

-- Block archiving the last admin of a team. Fires when:
--   (a) archived_at transitions NULL → NOT NULL on an admin row
--   (b) role demotes from admin → member on an unarchived row
CREATE OR REPLACE FUNCTION public.team_user_block_last_admin ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_other_admin_count int;
BEGIN
    SELECT count(*) INTO v_other_admin_count
    FROM public.team_user
    WHERE team_id = OLD.team_id
      AND role = 'admin'
      AND archived_at IS NULL
      AND id != OLD.id;
    IF v_other_admin_count = 0 THEN
        RAISE EXCEPTION 'cannot remove the last admin of team %', OLD.team_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER team_user_block_last_admin
    BEFORE UPDATE ON "public"."team_user"
    FOR EACH ROW
    WHEN (
        OLD.role = 'admin'
        AND (
            (OLD.archived_at IS NULL AND NEW.archived_at IS NOT NULL)
            OR (NEW.role != 'admin')
        )
    )
    EXECUTE FUNCTION public.team_user_block_last_admin ();

-- After archiving membership, archive the user's priorities for this team
-- (top-level and descendants). Per project convention (libs/db/AGENTS.md),
-- DO NOT cascade-archive descendants when archiving the top-level priority
-- directly — that's reversibility-preserving for personal priorities.
-- Here we're handling the team-leave path specifically: every priority
-- the user has scoped to this team must be archived, since they no longer
-- have access.
CREATE OR REPLACE FUNCTION public.team_user_archive_priorities ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE public.priority
    SET archived_at = COALESCE(archived_at, now())
    WHERE user_id = NEW.user_id
      AND team_id = NEW.team_id
      AND archived_at IS NULL;
    RETURN NULL;
END;
$$;

CREATE TRIGGER team_user_archive_priorities
    AFTER UPDATE ON "public"."team_user"
    FOR EACH ROW
    WHEN (OLD.archived_at IS NULL AND NEW.archived_at IS NOT NULL)
    EXECUTE FUNCTION public.team_user_archive_priorities ();
