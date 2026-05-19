-- Ensure user_contact rows exist for all contacts on a thread so that
-- external contacts (e.g. from Gmail, Slack connectors) are visible as
-- actors in the app. Fires after INSERT or UPDATE OF contacts on thread.
--
-- Cross-contact visibility is gated: a recipient only gains a user_contact
-- row pointing at another contact on the thread when they have an
-- independent right to see the thread's membership. Concretely, one of:
--   - they authored the thread
--   - one of their own linked contacts is on the thread (peer share)
--   - they admin one of the thread's groups (announce / private / team)
--   - they're a member of a `private` or `team` group on the thread
--     (matches user.group.member_contact_ids: public/announce groups do
--     not expose their member list to non-admin members)
-- This mirrors the visibility rule encoded in user.group.member_contact_ids:
-- non-admins of announce groups must not learn the other members' identities.
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

    -- ORDER BY (tp.user_id, arr.contact_id) locks rows in a stable order
    -- across concurrent transactions. Without it, two parallel upserts of
    -- threads with overlapping contacts/recipients can lock the same
    -- (user_id, contact_id) rows in different orders and deadlock.
    INSERT INTO user_contact (user_id, contact_id, linked, source)
    SELECT tp.user_id, arr.contact_id, false, 'thread'
    FROM thread_priority tp
    CROSS JOIN unnest(NEW.contacts) AS arr(contact_id)
    WHERE tp.thread_id = NEW.id
      AND EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
      AND (
            -- Author of the thread always sees membership. NOTE:
            -- thread.created_by may be a twist_instance_id for connector
            -- threads, in which case this predicate never matches and
            -- visibility is granted (or not) by the remaining clauses.
            tp.user_id = NEW.created_by
            -- Recipient's own linked contact is on the thread.
            OR EXISTS (
                SELECT 1
                FROM user_contact uc_self
                WHERE uc_self.user_id = tp.user_id
                  AND uc_self.linked = TRUE
                  AND uc_self.archived_at IS NULL
                  AND uc_self.contact_id = ANY(NEW.contacts)
            )
            -- Recipient is an admin of one of the thread's groups.
            OR EXISTS (
                SELECT 1
                FROM unnest(COALESCE(NEW.groups, ARRAY[]::uuid[])) AS gid
                JOIN group_admin ga ON ga.group_id = gid AND ga.user_id = tp.user_id
            )
            -- Recipient is a member of a private or team group on the thread.
            OR EXISTS (
                SELECT 1
                FROM unnest(COALESCE(NEW.groups, ARRAY[]::uuid[])) AS gid
                JOIN public."group" g ON g.id = gid AND g.type IN ('private', 'team')
                JOIN group_member gm ON gm.group_id = g.id
                JOIN user_contact uc_grp
                    ON uc_grp.contact_id = gm.contact_id
                   AND uc_grp.linked = TRUE
                   AND uc_grp.archived_at IS NULL
                WHERE uc_grp.user_id = tp.user_id
            )
      )
    ORDER BY tp.user_id, arr.contact_id
    ON CONFLICT (user_id, contact_id) DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER sync_user_contact_for_thread_contacts
    AFTER INSERT OR UPDATE OF contacts
    ON public.thread
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_user_contact_for_thread_contacts ();
