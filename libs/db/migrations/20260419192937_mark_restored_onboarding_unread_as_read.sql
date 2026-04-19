-- Repair the read state of onboarding thread_unread rows that were
-- recreated by 20260419165701_fix_everyone_eviction_and_backfill.
--
-- The previous migration's Step 2 (`UPDATE thread_unread SET read_at = now()
-- ... WHERE updated_at >= v_mark_cutoff`) silently matched zero rows because
-- of a now()/clock_timestamp() ordering bug:
--
--   v_mark_cutoff = clock_timestamp()  -- evaluated at DECLARE, AFTER txn start
--   thread_unread.updated_at = now()   -- set by BEFORE-INSERT trigger,
--                                       -- returns transaction_timestamp()
--
-- Inside any single transaction, transaction_timestamp() is strictly less
-- than any later clock_timestamp(), so the predicate `updated_at >= v_mark_cutoff`
-- is FALSE for every row the cascade trigger just inserted. The intended
-- "mark just-restored rows as read" UPDATE matched nothing, leaving the
-- restored thread_unread rows with read_at = NULL. In prod that surfaced
-- 197 phantom-unread rows across 33 users for the 7 onboarding threads,
-- and would have triggered scheduled push/email notifications about
-- "new" content that is in fact the unchanged onboarding tutorial.
--
-- Identification strategy: the broken backfill INSERTed N>1 group_member
-- rows into Everyone in a single statement, so every row in that batch
-- shares the same `created_at`. Single-user signups create exactly one
-- group_member at a unique microsecond, so a shared `created_at` is the
-- unambiguous fingerprint of a batch insertion. The cascade trigger sets
-- thread_unread.updated_at via the same transaction's now(), which equals
-- the batch's group_member.created_at. We use that join to target only the
-- thread_unread rows the cascade actually created — never touching rows
-- that pre-dated or post-dated the broken migration (e.g. legitimately
-- unread onboarding for new signups outside this batch).
--
-- Setting read_at = bumped_at = the batch timestamp (rather than now())
-- preserves the chronological invariant that read_at >= note time for
-- these long-published onboarding threads, which keeps notification
-- queries (which test `read_at IS NULL`) silent without falsely advancing
-- any "recently read" surfaces.
--
-- Idempotent: re-running is a no-op once read_at is set, since the
-- predicate `tu.read_at IS NULL` excludes already-repaired rows. Safe to
-- ship to envs that never experienced the bug — those have no qualifying
-- batches and the loop body never executes.

DO $$
DECLARE
    v_everyone_group_id uuid;
    r record;
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

    FOR r IN
        SELECT gm.created_at
        FROM group_member gm
        WHERE gm.group_id = v_everyone_group_id
        GROUP BY gm.created_at
        HAVING COUNT(*) > 1
    LOOP
        UPDATE thread_unread tu
        SET read_at = r.created_at,
            bumped_at = r.created_at
        FROM thread t
        WHERE tu.thread_id = t.id
          AND v_everyone_group_id = ANY(t.groups)
          AND tu.updated_at = r.created_at
          AND tu.read_at IS NULL;
    END LOOP;
END $$;
