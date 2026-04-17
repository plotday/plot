-- Ensure the global "Everyone" group exists, contains every linked primary
-- user_contact, and is referenced by onboarding threads via thread.groups +
-- thread.topic. Idempotent.
--
-- Background: migration 20260415202415_system_plot_twist_instance_and_onboarding
-- looked up the Everyone topic with an ambiguous predicate
-- (auto_maintained = TRUE AND team_id IS NULL LIMIT 1). On a fresh local reset
-- — where kris@plot.day is seeded by that same migration — the matching
-- user_contact trigger had already auto-created a per-user account topic for
-- her, so the LIMIT 1 matched *that* topic instead of falling into the
-- Everyone-creation branch. The per-user topic was later deleted by
-- 20260416205018_split_topic_into_group_and_thread_topic, which stripped the
-- now-dangling id out of thread.topics (renamed to thread.groups) — leaving
-- every onboarding thread with an empty groups array and no Everyone group at
-- all. No user ever gets thread_priority rows for onboarding content.
--
-- On production the Everyone topic exists (backfilled before kris's user was
-- seeded by this migration's ancestors), so this migration is a no-op there.

DO $$
DECLARE
    v_everyone_id uuid;
    v_author_id uuid;
BEGIN
    -- 1. Strict Everyone-group lookup. team_id / auto_publisher_id /
    --    auto_team_admin_team_id must all be NULL; match on the well-known
    --    name so this cannot collide with a future non-Everyone auto group
    --    (unique idx_group_auto_everyone already enforces one row per this
    --    shape, but we match defensively anyway).
    SELECT id INTO v_everyone_id
    FROM "group"
    WHERE auto_maintained = TRUE
      AND team_id IS NULL
      AND auto_publisher_id IS NULL
      AND auto_team_admin_team_id IS NULL
      AND name = 'Everyone';

    -- 2. Create it if missing. Prefer kris@plot.day as created_by; fall back
    --    to the oldest user. If no users exist yet, leave the migration a
    --    no-op — the next user-contact insert will still fail to auto-add to
    --    Everyone, but that's a problem for the seed step, not for us.
    IF v_everyone_id IS NULL THEN
        SELECT id INTO v_author_id FROM "user" WHERE email = 'kris@plot.day';
        IF v_author_id IS NULL THEN
            SELECT id INTO v_author_id FROM "user" ORDER BY created_at ASC LIMIT 1;
        END IF;
        IF v_author_id IS NULL THEN
            RETURN;
        END IF;

        INSERT INTO "group" (name, type, created_by, auto_maintained)
        VALUES ('Everyone', 'announce', v_author_id, TRUE)
        RETURNING id INTO v_everyone_id;
    END IF;

    -- 3. Ensure every linked primary user_contact is a member. The
    --    auto_maintain_everyone_group trigger handles future user_contact
    --    inserts; this backfill covers existing contacts created before the
    --    group was available.
    INSERT INTO group_member (group_id, contact_id)
    SELECT v_everyone_id, uc.contact_id
    FROM user_contact uc
    WHERE uc.linked = TRUE
      AND uc."primary" = TRUE
      AND uc.archived_at IS NULL
    ON CONFLICT (group_id, contact_id) DO NOTHING;

    -- 4. Attach Everyone to onboarding threads that don't already reference
    --    it. COALESCE preserves any existing topic value (e.g. 'priority:…'
    --    routing keys) and only fills topic when unset.
    UPDATE thread
    SET groups = ARRAY[v_everyone_id],
        topic  = COALESCE(topic, v_everyone_id::text)
    WHERE key IN ('welcome', 'priorities', 'connections', 'getting-around',
                  'twists', 'notifications', 'clean-up')
      AND NOT (v_everyone_id = ANY(COALESCE(groups, ARRAY[]::uuid[])));

    -- 5. Explicitly file thread_priority + thread_unread for every Everyone
    --    member on every onboarding thread, independent of trigger behavior
    --    (see 20260417010235_fix_group_filing_for_twist_authored_threads for
    --    why the UPDATE-fires-trigger path alone was insufficient here — it
    --    skipped twist-instance-owner consumers).
    INSERT INTO thread_priority (thread_id, user_id, priority_id)
    SELECT t.id,
           uc.user_id,
           public.classify_thread_for_user(uc.user_id, t.id)
    FROM thread t
    CROSS JOIN group_member gm
    JOIN user_contact uc
      ON uc.contact_id = gm.contact_id
     AND uc.linked = TRUE
     AND uc.archived_at IS NULL
    WHERE gm.group_id = v_everyone_id
      AND t.key IN ('welcome', 'priorities', 'connections', 'getting-around',
                    'twists', 'notifications', 'clean-up')
      AND public.classify_thread_for_user(uc.user_id, t.id) IS NOT NULL
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

    INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
    SELECT uc.user_id, t.id, 'inform-updates', 50
    FROM thread t
    CROSS JOIN group_member gm
    JOIN user_contact uc
      ON uc.contact_id = gm.contact_id
     AND uc.linked = TRUE
     AND uc.archived_at IS NULL
    WHERE gm.group_id = v_everyone_id
      AND t.key IN ('welcome', 'priorities', 'connections', 'getting-around',
                    'twists', 'notifications', 'clean-up')
    ON CONFLICT (user_id, thread_id) DO NOTHING;
END $$;
