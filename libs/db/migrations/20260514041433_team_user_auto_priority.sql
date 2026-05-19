-- Create "team_user_ensure_team_priority" function
CREATE FUNCTION "public"."team_user_ensure_team_priority" () RETURNS trigger LANGUAGE plpgsql AS $$
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
-- Create trigger "team_user_ensure_team_priority"
CREATE TRIGGER "team_user_ensure_team_priority" AFTER INSERT OR UPDATE ON "public"."team_user" FOR EACH ROW EXECUTE FUNCTION "public"."team_user_ensure_team_priority"();
