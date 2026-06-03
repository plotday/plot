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

-- After archiving membership (team-leave), revoke the leaving user's access
-- to this team's threads. Focuses are team-agnostic now (priority.team_id is
-- gone), so there are no per-team priorities to archive — team scope lives
-- solely on thread.team_id.
--
-- Threads scoped to this team become invisible to the user — the user.thread
-- team firewall (keyed on thread.team_id) excludes them once team_user is
-- archived. Without a matching access-loss signal the client strands its
-- local copies. Mark each affected thread_priority row as revoked so
-- "user".thread_redacted emits a cleanup stub and the client hard-deletes.
-- See libs/db/AGENTS.md "Handling Access Loss to Synced Entities".
CREATE OR REPLACE FUNCTION public.team_user_revoke_team_threads ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Revoke the leaving user's access to this team's threads (keyed on the
    -- thread's own team_id). External (customer) contacts are exempt — they
    -- keep access even after the user leaves the team.
    UPDATE public.thread_priority tp
    SET revoked_at = now()
    FROM public.thread t
    WHERE tp.thread_id = t.id
      AND tp.user_id = NEW.user_id
      AND t.team_id = NEW.team_id
      AND NOT (t.external_contacts && "user".user_contact_ids(NEW.user_id))
      AND tp.revoked_at IS NULL;
    RETURN NULL;
END;
$$;

CREATE TRIGGER team_user_revoke_team_threads
    AFTER UPDATE ON "public"."team_user"
    FOR EACH ROW
    WHEN (OLD.archived_at IS NULL AND NEW.archived_at IS NOT NULL)
    EXECUTE FUNCTION public.team_user_revoke_team_threads ();

-- On (re)joining a team — INSERT of an active membership or un-archiving an
-- existing one — restore the user's access to that team's threads that were
-- previously revoked. Prior thread_priority filing is preserved (we only flip
-- revoked_at back to NULL). Mirrors the un-revoke branch in
-- file_thread_priority_on_group_member_change.
CREATE OR REPLACE FUNCTION public.team_user_unrevoke_team_threads ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE public.thread_priority tp
    SET revoked_at = NULL
    FROM public.thread t
    WHERE tp.thread_id = t.id
      AND tp.user_id = NEW.user_id
      AND t.team_id = NEW.team_id
      AND tp.revoked_at IS NOT NULL;
    RETURN NULL;
END;
$$;

CREATE TRIGGER team_user_unrevoke_team_threads
    AFTER INSERT OR UPDATE ON "public"."team_user"
    FOR EACH ROW
    WHEN (NEW.archived_at IS NULL)
    EXECUTE FUNCTION public.team_user_unrevoke_team_threads ();
