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

        -- 5. Repair note ordering for onboarding threads
        -- Uses 1-minute interval for reliable ascending order
        WITH thread_notes AS (
            SELECT 
                n.id,
                t.created_at as thread_created_at,
                row_number() OVER (PARTITION BY n.thread_id ORDER BY n.created_at ASC) - 1 as note_order
            FROM note n
            JOIN thread t ON t.id = n.thread_id
            WHERE t.key IN ('welcome', 'priorities', 'connections', 'getting-around', 'twists', 'notifications', 'clean-up')
        )
        UPDATE note n
        SET source_created_at = tn.thread_created_at + (tn.note_order * interval '1 minute')
        FROM thread_notes tn
        WHERE n.id = tn.id;
    END IF;
END $$;

-- 6. Re-sync user schema views to include topic-based visibility
CREATE OR REPLACE VIEW "user"."note" AS
SELECT
    tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id
FROM
    note n
    JOIN thread a ON a.id = n.thread_id
    JOIN thread_priority tp ON tp.thread_id = a.id
WHERE
    -- Note-level filtering
    (n.draft = FALSE OR n.created_by = tp.user_id)
    AND (n.access_contacts IS NULL
        OR n.created_by = tp.user_id
        OR n.access_contacts && "user".user_contact_ids(tp.user_id))
    -- Thread-level filtering
    AND (a.draft = FALSE OR a.created_by = tp.user_id)
    AND (
        a.contacts && "user".user_contact_ids(tp.user_id)
        OR a.topics && "user".user_topic_ids(tp.user_id)
    );

CREATE OR REPLACE VIEW "user"."note_redacted" AS
SELECT
    tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    CAST(NULL AS uuid[]) AS access_contacts,
    NULL::text AS content,
    NULL::jsonb AS actions,
    CAST(NULL AS uuid[]) AS mentions,
    n.re_note_id,
    n.merged_from_thread_id
FROM
    note n
    JOIN thread a ON a.id = n.thread_id
    JOIN thread_priority tp ON tp.thread_id = a.id
WHERE
    (n.draft = FALSE OR n.created_by = tp.user_id)
    AND (a.draft = FALSE OR a.created_by = tp.user_id)
    AND (
        a.contacts && "user".user_contact_ids(tp.user_id)
        OR a.topics && "user".user_topic_ids(tp.user_id)
    )
    -- Hidden by note-level access restriction
    AND (n.access_contacts IS NOT NULL
        AND n.created_by != tp.user_id
        AND NOT (COALESCE(n.access_contacts, ARRAY[]::uuid[]) && "user".user_contact_ids(tp.user_id)));

