-- upsert_thread_read must clear the user's unread state.
--
-- Background: the Flutter client pushes a passive read (opening a thread that
-- carries no state flag, active=false) via POST /sync/thread-read, which calls
-- upsert_thread_read. The `unread` boolean on user.thread is derived solely
-- from public.thread_state.read_at. Historically upsert_thread_read wrote only
-- the legacy public.thread_read table (which now feeds twist onThreadRead
-- callbacks via twist_instance_thread_read), so a passive read never cleared
-- thread_state.read_at and the thread stayed unread forever — most visible on
-- system/onboarding threads whose thread_state row is seeded read_at=NULL and
-- which are only ever passively read.
--
-- The fix: upsert_thread_read now ALSO marks thread_state read, using the same
-- race-safe guard as clear_thread_state (only when read_at IS NULL and the
-- read timestamp is at/after the latest content), while still writing
-- thread_read for the twist-callback path.
--
-- Cases covered:
--   1. Passive read on an unread thread clears thread_state -> unread=false.
--   2. The legacy thread_read row is still written (twist-callback compat).
--   3. A stale read (before the latest content) does NOT mark thread_state
--      read — the race guard is respected (matches clear_thread_state).
--   4. The stale read still records a thread_read row (legacy is unconditional).
--
BEGIN;
SET LOCAL search_path = public, "user", extensions;

SELECT plan(6);

CREATE TEMP TABLE _ids (
    user_id uuid,
    user_contact_id uuid,
    thread_fresh uuid,   -- read at/after latest content
    thread_stale uuid,   -- read before latest content
    priority_id uuid
);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_user_contact uuid;
    v_priority uuid;
    v_t_fresh uuid := gen_random_uuid();
    v_t_stale uuid := gen_random_uuid();
    v_content timestamptz := '2026-01-01 12:00:00+00';
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'reader@test.local');
    v_user_contact := public.upsert_user_contact(v_user, 'reader@test.local', 'Reader', NULL);
    SELECT id INTO v_priority FROM public.priority WHERE user_id = v_user LIMIT 1;

    -- Two visible threads authored by the user, each carrying the user's
    -- contact so user.thread surfaces them. last_note_source_created_at fixes
    -- the content high-water mark the read guard compares against.
    INSERT INTO public.thread (id, created_by, title, contacts, last_note_source_created_at)
    VALUES (v_t_fresh, v_user, 'fresh', ARRAY[v_user_contact], v_content),
           (v_t_stale, v_user, 'stale', ARRAY[v_user_contact], v_content);

    -- Settled filings so both threads are visible in user.thread.
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_t_fresh, v_user, v_priority),
           (v_t_stale, v_user, v_priority);

    -- Seed an UNREAD thread_state row for each (read_at NULL), like the
    -- onboarding/system seed that triggers the bug.
    INSERT INTO public.thread_state (user_id, thread_id, read_at, importance)
    VALUES (v_user, v_t_fresh, NULL, 50),
           (v_user, v_t_stale, NULL, 50);

    INSERT INTO _ids VALUES (v_user, v_user_contact, v_t_fresh, v_t_stale, v_priority);
END $$;

-- Precondition: both threads start unread in user.thread.
SELECT is(
    (SELECT count(*)::int FROM "user".thread ut, _ids
      WHERE ut.user_id = _ids.user_id
        AND ut.id IN (_ids.thread_fresh, _ids.thread_stale)
        AND ut.unread = TRUE),
    2,
    'precondition: both seeded threads are unread'
);

-- ---------------------------------------------------------------------------
-- Case 1+2: passive read at/after latest content clears unread AND writes
-- the legacy thread_read row.
-- ---------------------------------------------------------------------------
SELECT "user".upsert_thread_read(
    (SELECT user_id FROM _ids),
    (SELECT thread_fresh FROM _ids),
    '2026-01-01 12:00:00+00'::timestamptz,  -- p_read_at == content high-water
    NULL
);

SELECT ok(
    (SELECT ts.read_at IS NOT NULL
       FROM thread_state ts, _ids
      WHERE ts.user_id = _ids.user_id AND ts.thread_id = _ids.thread_fresh),
    'case 1: thread_state.read_at is set after upsert_thread_read'
) FROM _ids LIMIT 1;

SELECT is(
    (SELECT ut.unread FROM "user".thread ut, _ids
      WHERE ut.user_id = _ids.user_id AND ut.id = _ids.thread_fresh),
    FALSE,
    'case 1: user.thread.unread is now false'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM thread_read tr, _ids
         WHERE tr.user_id = _ids.user_id AND tr.thread_id = _ids.thread_fresh
           AND tr.read_at IS NOT NULL
    ),
    'case 2: legacy thread_read row still written (twist-callback compat)'
) FROM _ids LIMIT 1;

-- ---------------------------------------------------------------------------
-- Case 3+4: a stale read (before the latest content) must NOT mark
-- thread_state read (race guard), but still records thread_read.
-- ---------------------------------------------------------------------------
SELECT "user".upsert_thread_read(
    (SELECT user_id FROM _ids),
    (SELECT thread_stale FROM _ids),
    '2025-12-31 12:00:00+00'::timestamptz,  -- p_read_at < content high-water
    NULL
);

SELECT is(
    (SELECT ut.unread FROM "user".thread ut, _ids
      WHERE ut.user_id = _ids.user_id AND ut.id = _ids.thread_stale),
    TRUE,
    'case 3: stale read does not clear unread (race guard respected)'
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM thread_read tr, _ids
         WHERE tr.user_id = _ids.user_id AND tr.thread_id = _ids.thread_stale
           AND tr.read_at IS NOT NULL
    ),
    'case 4: stale read still records a thread_read row (legacy unconditional)'
) FROM _ids LIMIT 1;

SELECT * FROM finish();
ROLLBACK;
