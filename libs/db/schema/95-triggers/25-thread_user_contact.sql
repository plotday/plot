-- Ensure user_contact rows exist for all contacts on a thread so that
-- external contacts (e.g. from Gmail, Slack connectors) are visible as
-- actors in the app. Fires after INSERT or UPDATE OF contacts on thread,
-- and creates unlinked user_contact rows for every user who has a
-- thread_priority row on that thread.
--
-- Named with sync_ prefix so it fires alphabetically after
-- file_thread_priority_peers (f < s), ensuring peer thread_priority
-- rows exist before we look them up.
CREATE OR REPLACE FUNCTION public.sync_user_contact_for_thread_contacts ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
    END IF;

    INSERT INTO user_contact (user_id, contact_id, linked, source)
    SELECT tp.user_id, arr.contact_id, false, 'thread'
    FROM thread_priority tp
    CROSS JOIN unnest(NEW.contacts) AS arr(contact_id)
    WHERE tp.thread_id = NEW.id
      AND EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
    ON CONFLICT (user_id, contact_id) DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER sync_user_contact_for_thread_contacts
    AFTER INSERT OR UPDATE OF contacts
    ON public.thread
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_user_contact_for_thread_contacts ();
