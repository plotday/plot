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
-- Re-justification (un-redact): when the predicate PASSES for a (user, contact)
-- pair that already has a redacted row, the ON CONFLICT clause un-archives it
-- instead of leaving it tombstoned. The 20260505 redact_contact_leakage
-- migration archived thread-sourced (linked = false) user_contact rows that
-- FAILED this exact predicate; user.actor then emits a name/email-NULL
-- tombstone, so the contact renders as "Unknown" even on threads the user can
-- now see. Un-archiving here is the precise inverse of that sweep under the
-- same justification rule — it restores the actor's identity without
-- re-leaking, and the UPDATE bumps user_contact.seq so clients re-pull the
-- now-named row. Scoped to linked = false / source = 'thread' so it can never
-- touch self or linked address-book rows.
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
    -- Only touches archived_at; never writes `name`, so a per-user name set by
    -- upsert_user_contact_name (source = 'observed') is preserved.
    ON CONFLICT (user_id, contact_id) DO UPDATE
        SET archived_at = NULL
        WHERE user_contact.archived_at IS NOT NULL
          AND user_contact.linked = false
          AND user_contact.source = 'thread';

    RETURN NEW;
END;
$$;

CREATE TRIGGER sync_user_contact_for_thread_contacts
    AFTER INSERT OR UPDATE OF contacts
    ON public.thread
    FOR EACH ROW
    EXECUTE FUNCTION public.sync_user_contact_for_thread_contacts ();
