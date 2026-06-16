-- Per-user scoped-note source time (spec 2026-06-16):
--   A scoped note must NOT advance the shared thread.last_note_source_created_at
--   (no leak), but MUST record its source_created_at on thread_state for each
--   visible user. user.thread then projects GREATEST(shared, per-user) so the
--   client's displayed source time is correct, and clear_thread_state's read
--   guard uses the same formula so reads still stick when source < created_at.
--
-- Notes are inserted directly (not via upsert_note) to exercise the
-- update_thread_on_note_change trigger in isolation, matching test 42.
BEGIN;
SET LOCAL search_path = public, "user", extensions;
SELECT plan(6);

DO $$
DECLARE
    v_author   uuid := gen_random_uuid();
    v_author_c uuid;
    v_thread   uuid := gen_random_uuid();
BEGIN
    INSERT INTO "user" (id, email) VALUES (v_author, 'srctime-author@test.local');
    SELECT contact_id INTO v_author_c FROM user_contact
        WHERE user_id = v_author AND "primary" = TRUE AND linked = TRUE LIMIT 1;

    -- Thread created "now"; its notes' source times are deliberately earlier
    -- (mirrors a synced email that predates ingestion).
    INSERT INTO thread (id, created_by, title, contacts, last_note_seq, created_at)
        VALUES (v_thread, v_author, 'T', ARRAY[v_author_c], '0'::xid8, now());

    -- Settle the author's thread_priority filing (raw INSERT does not).
    INSERT INTO thread_priority (thread_id, user_id, priority_id)
    SELECT v_thread, v_author, p.id FROM priority p
        WHERE p.user_id = v_author AND nlevel(p.path) = 1 LIMIT 1
    ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET priority_id = EXCLUDED.priority_id, classify_at = NULL;

    PERFORM set_config('test.author',   v_author::text,   false);
    PERFORM set_config('test.author_c', v_author_c::text, false);
    PERFORM set_config('test.thread',   v_thread::text,   false);
END $$;

-- Insert a SCOPED note (access_contacts = [author]) dated 5 days before now.
INSERT INTO note (id, author_id, created_by, thread_id, draft, access_contacts, content, source_created_at)
VALUES (gen_random_uuid(),
        current_setting('test.author_c')::uuid,
        current_setting('test.author')::uuid,
        current_setting('test.thread')::uuid, FALSE,
        ARRAY[current_setting('test.author_c')::uuid],
        'scoped', now() - interval '5 days');

-- 1. Scoped note must NOT advance the shared thread column (no leak).
SELECT is(
    (SELECT last_note_source_created_at FROM thread WHERE id = current_setting('test.thread')::uuid),
    NULL::timestamptz,
    'scoped note leaves shared thread.last_note_source_created_at NULL');

-- 2. Scoped note records its source time on the author's thread_state row.
SELECT is(
    (SELECT last_note_source_created_at FROM thread_state
        WHERE thread_id = current_setting('test.thread')::uuid
          AND user_id = current_setting('test.author')::uuid),
    (now() - interval '5 days')::timestamptz,
    'scoped note sets thread_state.last_note_source_created_at for the visible user');

-- 3. user.thread projects the per-user value (GREATEST picks the ts column).
SELECT is(
    (SELECT last_note_source_created_at FROM "user".thread
        WHERE id = current_setting('test.thread')::uuid
          AND user_id = current_setting('test.author')::uuid),
    (now() - interval '5 days')::timestamptz,
    'user.thread projects the scoped per-user source time');

-- Insert a NEWER scoped note (3 days before now) — projection must advance.
INSERT INTO note (id, author_id, created_by, thread_id, draft, access_contacts, content, source_created_at)
VALUES (gen_random_uuid(),
        current_setting('test.author_c')::uuid,
        current_setting('test.author')::uuid,
        current_setting('test.thread')::uuid, FALSE,
        ARRAY[current_setting('test.author_c')::uuid],
        'scoped-newer', now() - interval '3 days');

-- 4. GREATEST advances to the newer scoped source time.
SELECT is(
    (SELECT last_note_source_created_at FROM "user".thread
        WHERE id = current_setting('test.thread')::uuid
          AND user_id = current_setting('test.author')::uuid),
    (now() - interval '3 days')::timestamptz,
    'a newer scoped note advances the per-user projected source time');

-- 5. Read-stick: the trigger auto-read the author's row (author-match branch),
--    so reset it to UNREAD first to genuinely exercise the guard (otherwise this
--    passes vacuously). Marking read with p_read_at = the projected source time
--    (which is BEFORE thread.created_at = now) must be ACCEPTED. Regression
--    guard: a wrong formula (GREATEST(..., created_at)) would reject it and the
--    thread would stick unread forever.
UPDATE thread_state SET read_at = NULL
 WHERE thread_id = current_setting('test.thread')::uuid
   AND user_id = current_setting('test.author')::uuid;

SELECT "user".clear_thread_state(
    current_setting('test.author')::uuid,
    current_setting('test.thread')::uuid,
    (now() - interval '3 days')::timestamptz,   -- p_read_at == projected source time
    NULL);

SELECT is(
    (SELECT read_at FROM thread_state
        WHERE thread_id = current_setting('test.thread')::uuid
          AND user_id = current_setting('test.author')::uuid),
    (now() - interval '3 days')::timestamptz,
    'read at the projected source time sticks even though source < created_at');

-- 6. An UNSCOPED note still bumps the shared column.
INSERT INTO note (id, author_id, created_by, thread_id, draft, content, source_created_at)
VALUES (gen_random_uuid(),
        current_setting('test.author_c')::uuid,
        current_setting('test.author')::uuid,
        current_setting('test.thread')::uuid, FALSE,
        'public', now() - interval '1 day');

SELECT is(
    (SELECT last_note_source_created_at FROM thread WHERE id = current_setting('test.thread')::uuid),
    (now() - interval '1 day')::timestamptz,
    'unscoped note advances the shared thread.last_note_source_created_at');

SELECT * FROM finish();
ROLLBACK;
