-- Modify "sync_user_contact_for_thread_contacts" function
CREATE OR REPLACE FUNCTION "public"."sync_user_contact_for_thread_contacts" () RETURNS trigger LANGUAGE plpgsql AS $$
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
      AND (
            -- Author of the thread always sees membership.
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
            -- Recipient is a member of a non-announce group on the thread.
            OR EXISTS (
                SELECT 1
                FROM unnest(COALESCE(NEW.groups, ARRAY[]::uuid[])) AS gid
                JOIN public."group" g ON g.id = gid AND g.type <> 'announce'
                JOIN group_member gm ON gm.group_id = g.id
                JOIN user_contact uc_grp
                    ON uc_grp.contact_id = gm.contact_id
                   AND uc_grp.linked = TRUE
                   AND uc_grp.archived_at IS NULL
                WHERE uc_grp.user_id = tp.user_id
            )
      )
    ON CONFLICT (user_id, contact_id) DO NOTHING;

    RETURN NEW;
END;
$$;
