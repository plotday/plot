-- Repair onboarding thread visibility and primary contact consistency.
-- Skips re-scheduling for existing users as they likely already finished them.

-- Disable automatic onboarding schedules for this session
SET LOCAL plot.skip_onboarding_schedules = 'true';

DO $$
DECLARE
    v_everyone_topic_id uuid;
BEGIN
    -- 1. Ensure every user has a primary contact
    -- Promotes the first linked contact to primary if none exists.
    UPDATE user_contact uc
    SET "primary" = TRUE
    WHERE uc.linked = TRUE
      AND uc.archived_at IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM user_contact uc2
          WHERE uc2.user_id = uc.user_id
            AND uc2."primary" = TRUE
      )
      AND uc.contact_id = (
          SELECT uc3.contact_id FROM user_contact uc3
          WHERE uc3.user_id = uc.user_id
            AND uc3.linked = TRUE
            AND uc3.archived_at IS NULL
          ORDER BY uc3.created_at ASC
          LIMIT 1
      );

    -- 2. Get the "Everyone" announce topic
    SELECT id INTO v_everyone_topic_id
    FROM topic
    WHERE auto_maintained = TRUE AND team_id IS NULL
    LIMIT 1;

    IF v_everyone_topic_id IS NOT NULL THEN
        -- 3. Ensure all primary contacts are in the Everyone topic
        INSERT INTO topic_member (topic_id, contact_id)
        SELECT v_everyone_topic_id, uc.contact_id
        FROM user_contact uc
        WHERE uc.linked = TRUE
          AND uc."primary" = TRUE
          AND uc.archived_at IS NULL
        ON CONFLICT DO NOTHING;

        -- 4. File onboarding threads for all Everyone topic members
        -- This covers the creator (Kris) and any users who were missing them.
        INSERT INTO thread_priority (thread_id, user_id, priority_id)
        SELECT t.id, uc.user_id, public.classify_thread_for_user(uc.user_id, t.id)
        FROM thread t
        CROSS JOIN topic_member tm
        JOIN user_contact uc ON uc.contact_id = tm.contact_id
        WHERE t.key IN ('welcome', 'priorities', 'connections', 'getting-around', 'twists', 'notifications', 'clean-up')
          AND tm.topic_id = v_everyone_topic_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;
    END IF;
END $$;
