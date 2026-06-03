-- Maintains thread.team_id and thread.external_contacts.
--
-- team_id:
--   • INSERT: if NULL and created_by is a twist_instance, inherit that
--     connection's team (connector threads are team threads). User threads
--     pass team_id explicitly via upsert_thread.
--   • UPDATE: locked once set (NULL→value allowed once, for backfill or a
--     personal→team promotion).
--
-- external_contacts (only for team-scoped threads): the subset of contacts
-- exempt from the team-membership gate. POINT-IN-TIME — a contact added
-- while NOT a current member of team_id is recorded as external and stays
-- exempt; a contact added while a member is left gated (so it loses access
-- if it later leaves the team). Prior external decisions are preserved for
-- contacts still present; classification re-runs only for newly-added
-- contacts (or all contacts when the thread first becomes team-scoped).
CREATE OR REPLACE FUNCTION public.set_thread_team_and_external ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_old_contacts uuid[] := ARRAY[]::uuid[];
    v_old_external uuid[] := ARRAY[]::uuid[];
    v_classify_all boolean := FALSE;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.team_id IS NULL THEN
            -- Connector-created threads inherit the connection's team.
            SELECT ti.team_id INTO NEW.team_id
            FROM twist_instance ti
            WHERE ti.id = NEW.created_by;
        END IF;
        v_classify_all := (NEW.team_id IS NOT NULL);
    ELSE  -- UPDATE
        v_old_contacts := COALESCE(OLD.contacts, ARRAY[]::uuid[]);
        v_old_external := COALESCE(OLD.external_contacts, ARRAY[]::uuid[]);
        IF OLD.team_id IS NOT NULL AND NEW.team_id IS DISTINCT FROM OLD.team_id THEN
            NEW.team_id := OLD.team_id;  -- locked once set
        END IF;
        -- NULL→value transition (backfill / promotion) reclassifies all
        -- current contacts at this instant.
        v_classify_all := (OLD.team_id IS NULL AND NEW.team_id IS NOT NULL);
    END IF;

    IF NEW.team_id IS NULL THEN
        NEW.external_contacts := ARRAY[]::uuid[];
        RETURN NEW;
    END IF;

    NEW.external_contacts := (
        SELECT COALESCE(array_agg(DISTINCT c), ARRAY[]::uuid[])::uuid[]
        FROM (
            -- Prior external decisions, limited to still-present contacts.
            SELECT c FROM unnest(v_old_external) AS c
            WHERE c = ANY(COALESCE(NEW.contacts, ARRAY[]::uuid[]))
            UNION
            -- Newly-added (or all, when first team-scoped) contacts with no
            -- current member of NEW.team_id linked to them → exempt.
            SELECT c FROM unnest(COALESCE(NEW.contacts, ARRAY[]::uuid[])) AS c
            WHERE (v_classify_all OR c <> ALL(v_old_contacts))
              AND NOT EXISTS (
                  SELECT 1
                  FROM user_contact uc
                  JOIN team_user tu
                    ON tu.user_id = uc.user_id
                   AND tu.team_id = NEW.team_id
                   AND tu.archived_at IS NULL
                  WHERE uc.contact_id = c
                    AND uc.linked = TRUE
                    AND uc.archived_at IS NULL
              )
        ) s
    );

    RETURN NEW;
END;
$$;

-- Fire on the columns that affect the computation. Including external_contacts
-- in the OF list means any direct write to it is re-sanitized (recomputed),
-- so the column stays server-controlled.
CREATE TRIGGER set_thread_team_and_external
    BEFORE INSERT OR UPDATE OF contacts, team_id, external_contacts, created_by
    ON public.thread
    FOR EACH ROW
    EXECUTE FUNCTION public.set_thread_team_and_external ();
