-- Quiet classify_at-only thread_priority writes (classify-worker contention fix).
--
-- The classify worker's "same result" settle (UPDATE ... SET classify_at = NULL)
-- and the reclassify/channel/topic markers (SET classify_at = now()) change only
-- the internal classify_at column — they never change what any user.* view
-- returns. Yet every such write used to fire the AFTER-statement
-- user_sync_thread_priority_update trigger, upserting the per-user singleton
-- user_sync(user_id,'thread') row. Under reclassify churn those no-op writes
-- dominate the singleton's write rate and serialize on its row lock, backing up
-- to the statement timeout (PostHog 019ed55a). They must be QUIET: no
-- user_sync bump.
--
-- Observability note: pg_current_xact_id() is constant within a transaction, so
-- a fired trigger and a quiet one would both stamp the same xid. We instead reset
-- user_sync.last_update_seq to the '0' sentinel after setup; a fired trigger then
-- jumps it to the (large) txn xid, while a quiet write leaves it at '0'.
BEGIN;
SET LOCAL search_path = public, "user", extensions;
SELECT plan(6);

DO $$
DECLARE
    v_user      uuid := gen_random_uuid();
    v_user_c    uuid;
    v_root      uuid;
    v_other     uuid;
    v_thread    uuid := gen_random_uuid();
BEGIN
    INSERT INTO "user" (id, email) VALUES (v_user, 'mover@test.local');
    SELECT contact_id INTO v_user_c FROM user_contact
        WHERE user_id = v_user AND "primary" = TRUE AND linked = TRUE LIMIT 1;
    SELECT id INTO v_root FROM priority
        WHERE user_id = v_user AND nlevel(path) = 1 LIMIT 1;

    -- A second priority (nested under root, role_id inherited) to move the
    -- thread into (negative control). nlevel(path) > 1 satisfies
    -- validate_priority_root; role_id satisfies priority_role_or_fyi.
    v_other := gen_random_uuid();
    INSERT INTO priority (id, user_id, created_by, path, title, role_id)
        SELECT v_other, v_user, v_user,
               p.path || text2ltree(replace(v_other::text, '-', '')), 'Other', p.role_id
          FROM priority p WHERE p.id = v_root;

    INSERT INTO thread (id, created_by, title, contacts)
        VALUES (v_thread, v_user, 'T', ARRAY[v_user_c]);

    -- Settled filing (priority_id set, classify_at NULL): the row state the
    -- classify worker leaves behind and the reclassify markers re-mark.
    INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
        VALUES (v_thread, v_user, v_root, NULL);

    PERFORM set_config('test.user', v_user::text, false);
    PERFORM set_config('test.thread', v_thread::text, false);
    PERFORM set_config('test.other', v_other::text, false);
END $$;

-- Helper: reset the user's 'thread' sync watermark to the '0' sentinel so a
-- subsequent fired trigger is observable as a jump above '0'.
CREATE OR REPLACE FUNCTION pg_temp.reset_sync() RETURNS void LANGUAGE sql AS $$
    UPDATE user_sync SET last_update_seq = '0'::xid8, last_update_at = '1999-01-01'
     WHERE user_id = current_setting('test.user')::uuid AND entity = 'thread';
$$;

CREATE OR REPLACE FUNCTION pg_temp.thread_sync_seq() RETURNS xid8 LANGUAGE sql AS $$
    SELECT last_update_seq FROM user_sync
     WHERE user_id = current_setting('test.user')::uuid AND entity = 'thread';
$$;

-- Sanity: the settled INSERT bumped user_sync above '0'.
SELECT cmp_ok(pg_temp.thread_sync_seq(), '>', '0'::xid8,
    'precondition: settled thread_priority INSERT bumped user_sync(thread)');

-- 1. classify_at MARKER (reclassify re-mark): priority unchanged, only
--    classify_at set. Must NOT bump user_sync.
SELECT pg_temp.reset_sync();
UPDATE thread_priority SET classify_at = now()
 WHERE user_id = current_setting('test.user')::uuid
   AND thread_id = current_setting('test.thread')::uuid;
SELECT is(pg_temp.thread_sync_seq(), '0'::xid8,
    'classify_at marker (priority unchanged) leaves user_sync(thread) quiet');

-- 2. classify_at CLEAR (the worker "same result" branch): only classify_at
--    cleared. Must NOT bump user_sync.
SELECT pg_temp.reset_sync();
UPDATE thread_priority SET classify_at = NULL
 WHERE user_id = current_setting('test.user')::uuid
   AND thread_id = current_setting('test.thread')::uuid;
SELECT is(pg_temp.thread_sync_seq(), '0'::xid8,
    'classify_at clear (same-result settle) leaves user_sync(thread) quiet');

-- 3. NEGATIVE CONTROL: a priority_id change (real filing) MUST bump user_sync.
SELECT pg_temp.reset_sync();
UPDATE thread_priority SET priority_id = current_setting('test.other')::uuid, classify_at = NULL
 WHERE user_id = current_setting('test.user')::uuid
   AND thread_id = current_setting('test.thread')::uuid;
SELECT cmp_ok(pg_temp.thread_sync_seq(), '>', '0'::xid8,
    'priority_id change (real filing) DOES bump user_sync(thread)');

-- 4. NEGATIVE CONTROL: an archived_at change (per-user archive) MUST bump.
SELECT pg_temp.reset_sync();
UPDATE thread_priority SET archived_at = now()
 WHERE user_id = current_setting('test.user')::uuid
   AND thread_id = current_setting('test.thread')::uuid;
SELECT cmp_ok(pg_temp.thread_sync_seq(), '>', '0'::xid8,
    'archived_at change (per-user archive) DOES bump user_sync(thread)');

-- 5. NEGATIVE CONTROL: a priority change AND classify_at clear together (the
--    worker "moved"/"settled" branch) MUST bump — proves we key on the real
--    column, not merely "classify_at absent from the SET list".
SELECT pg_temp.reset_sync();
UPDATE thread_priority
   SET priority_id = current_setting('test.other')::uuid, classify_at = now()
 WHERE user_id = current_setting('test.user')::uuid
   AND thread_id = current_setting('test.thread')::uuid;
-- (priority_id is already test.other from step 3, so set it back-and-forth: use root)
UPDATE thread_priority
   SET priority_id = (SELECT id FROM priority WHERE user_id = current_setting('test.user')::uuid AND nlevel(path)=1 LIMIT 1),
       classify_at = NULL
 WHERE user_id = current_setting('test.user')::uuid
   AND thread_id = current_setting('test.thread')::uuid;
SELECT cmp_ok(pg_temp.thread_sync_seq(), '>', '0'::xid8,
    'priority change with classify_at clear (moved settle) DOES bump user_sync(thread)');

SELECT * FROM finish();
ROLLBACK;
