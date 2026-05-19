-- Create "team_user_archive_priorities" function
CREATE FUNCTION "public"."team_user_archive_priorities" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE public.priority
    SET archived_at = COALESCE(archived_at, now())
    WHERE user_id = NEW.user_id
      AND team_id = NEW.team_id
      AND archived_at IS NULL;
    RETURN NULL;
END;
$$;
-- Create trigger "team_user_archive_priorities"
CREATE TRIGGER "team_user_archive_priorities" AFTER UPDATE ON "public"."team_user" FOR EACH ROW WHEN ((old.archived_at IS NULL) AND (new.archived_at IS NOT NULL)) EXECUTE FUNCTION "public"."team_user_archive_priorities"();
-- Create "team_user_block_last_admin" function
CREATE FUNCTION "public"."team_user_block_last_admin" () RETURNS trigger LANGUAGE plpgsql AS $$
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
-- Create trigger "team_user_block_last_admin"
CREATE TRIGGER "team_user_block_last_admin" BEFORE UPDATE ON "public"."team_user" FOR EACH ROW WHEN ((old.role = 'admin'::public.team_role) AND (((old.archived_at IS NULL) AND (new.archived_at IS NOT NULL)) OR (new.role <> 'admin'::public.team_role))) EXECUTE FUNCTION "public"."team_user_block_last_admin"();
