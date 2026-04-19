-- Modify "auto_maintain_everyone_group" function
CREATE OR REPLACE FUNCTION "public"."auto_maintain_everyone_group" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_everyone_group_id uuid;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.linked = TRUE AND NEW."primary" = TRUE THEN
        SELECT id INTO v_everyone_group_id
        FROM "group"
        WHERE auto_maintained = TRUE AND team_id IS NULL AND auto_publisher_id IS NULL;

        IF v_everyone_group_id IS NOT NULL THEN
            INSERT INTO group_member (group_id, contact_id)
            VALUES (v_everyone_group_id, NEW.contact_id)
            ON CONFLICT DO NOTHING;
        END IF;

    ELSIF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND (
        NEW.linked = FALSE OR NEW."primary" = FALSE OR NEW.archived_at IS NOT NULL
    )) THEN
        SELECT id INTO v_everyone_group_id
        FROM "group"
        WHERE auto_maintained = TRUE AND team_id IS NULL AND auto_publisher_id IS NULL;

        -- Only evict the contact from Everyone when no other qualifying
        -- self-link still claims it. Without this guard, deleting a
        -- source='thread' user_contact cross-link (e.g. the
        -- 20260418050000 / 20260418053000 cleanups) would cascade-remove
        -- the contact's primary owner from Everyone even though their
        -- source='self' link is still intact. This is an AFTER trigger,
        -- so for UPDATE the row's new state is already visible to the
        -- subquery — if NEW.linked=false (or primary=false, archived),
        -- it's already excluded by the qualifying predicate.
        IF v_everyone_group_id IS NOT NULL THEN
            DELETE FROM group_member
            WHERE group_id = v_everyone_group_id
              AND contact_id = COALESCE(OLD.contact_id, NEW.contact_id)
              AND NOT EXISTS (
                SELECT 1 FROM user_contact uc
                WHERE uc.contact_id = COALESCE(OLD.contact_id, NEW.contact_id)
                  AND uc.linked = TRUE
                  AND uc."primary" = TRUE
                  AND uc.archived_at IS NULL
              );
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Data repair: restore Everyone membership (and cascaded thread_priority /
-- thread_unread rows) for users who were evicted by the bug in the previous
-- version of auto_maintain_everyone_group.
--
-- On 2026-04-18 05:01:41 and 05:01:43, the repair_onboarding_thread_ownership
-- and clear_remaining_onboarding_contacts migrations each ran
-- DELETE FROM user_contact WHERE source = 'thread'. Every row deletion fired
-- the unconditional eviction branch of auto_maintain_everyone_group, which
-- removed OLD.contact_id from Everyone even when a linked=TRUE, primary=TRUE,
-- source='self' row for the same contact still existed. The downstream
-- file_thread_priority_on_group_member_change trigger then dropped those
-- users' thread_priority rows for the 7 onboarding threads (where Everyone
-- was the only visibility path, thread.contacts having been cleared to {}
-- in the same migrations).
--
-- Restoration:
--   1. INSERT missing group_member rows for every qualifying user_contact
--      that isn't already in Everyone. The file_thread_priority_on_group_member_change
--      INSERT trigger fires per row and files thread_priority + thread_unread
--      for every onboarding thread the user should see.
--   2. Mark the resulting thread_unread rows as read (read_at = now()) so
--      the restoration does not surface 6 "new unread" threads per user or
--      trigger scheduled notifications. Only the 7 onboarding threads
--      reference Everyone, so this UPDATE is scoped accordingly — other
--      threads are unaffected.

DO $$
DECLARE
    v_everyone_group_id uuid;
    v_mark_cutoff timestamptz := clock_timestamp();
BEGIN
    SELECT id INTO v_everyone_group_id
    FROM "group"
    WHERE auto_maintained = TRUE
      AND team_id IS NULL
      AND auto_publisher_id IS NULL
      AND name = 'Everyone'
    LIMIT 1;

    IF v_everyone_group_id IS NULL THEN
        RETURN;
    END IF;

    -- 1. Restore missing Everyone memberships. ON CONFLICT DO NOTHING keeps
    --    this idempotent (safe to re-run and safe to replay against a
    --    database that already has the row). The
    --    file_thread_priority_on_group_member_change INSERT trigger fires
    --    per row and files thread_priority + thread_unread for every
    --    thread where Everyone is a member (in this db: only the 7
    --    onboarding threads).
    INSERT INTO group_member (group_id, contact_id)
    SELECT v_everyone_group_id, uc.contact_id
    FROM user_contact uc
    WHERE uc.linked = TRUE
      AND uc."primary" = TRUE
      AND uc.archived_at IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM group_member gm
          WHERE gm.group_id = v_everyone_group_id
            AND gm.contact_id = uc.contact_id
      )
    ON CONFLICT (group_id, contact_id) DO NOTHING;

    -- 2. Mark the thread_unread rows the INSERT trigger just created as
    --    already read. The cascade trigger creates rows with urgency
    --    'inform-updates', importance 50, read_at NULL — the same shape
    --    new-user onboarding seeds. Without this update, 6 onboarding
    --    threads per restored user would show as unread and fire scheduled
    --    notifications. The cutoff restricts this to rows we just created
    --    (existing thread_unread rows — e.g. for the 9 users who never
    --    lost their filing — were bumped only up to the INSERT fan-out
    --    when the cascade trigger short-circuited on ON CONFLICT DO
    --    NOTHING, so their updated_at stays pre-cutoff; we leave them
    --    alone).
    UPDATE thread_unread tu
    SET read_at = now(),
        bumped_at = now()
    FROM thread t
    WHERE tu.thread_id = t.id
      AND v_everyone_group_id = ANY(t.groups)
      AND tu.read_at IS NULL
      AND tu.updated_at >= v_mark_cutoff;
END $$;
