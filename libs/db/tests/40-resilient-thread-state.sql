-- Resilient upsert_thread_state: tolerate ordering between /sync/threads
-- and /sync/thread-state.
--
-- Background: the Flutter client fires three independent /sync/* pushes
-- when creating a new Tag.todo thread (thread, notes, thread-state). In
-- Cloudflare Workers these are independent invocations and arrive out of
-- order. When thread-state arrives before the thread_priority row exists,
-- the old upsert_thread_state raised 'Thread not found'; the route caught
-- it and silently dropped the push, so the task never showed up in Active.
--
-- The fix: instead of raising, defer the payload into pending_thread_state.
-- An AFTER-INSERT/UPDATE trigger on thread_priority applies the deferred
-- payload as soon as the user gains access. If access never lands, or is
-- revoked, the pending row stays put (it can't leak into thread_state
-- without a valid thread_priority).
--
-- Cases covered:
--  1. Push arrives BEFORE thread_priority → deferred (no thread_state).
--  2. thread_priority insert flushes pending → thread_state applied,
--     pending row deleted.
--  3. Push arrives for a REVOKED thread_priority → deferred, NOT applied.
--  4. Push arrives for a thread_priority with priority_id NULL (pending
--     classification) → deferred, NOT applied.
--  5. Second pending push for same (user, thread) overwrites the first.
--  6. Re-grant (revoked_at NULL → NOT NULL → NULL) flushes pending.
--
BEGIN;
SET LOCAL search_path = public, "user", extensions;

SELECT plan(14);

CREATE TEMP TABLE _ids (
    user_id uuid,
    user_contact_id uuid,
    thread_id_no_tp uuid,         -- no thread_priority yet
    thread_id_after uuid,         -- thread_priority created later
    thread_id_revoked uuid,       -- thread_priority but revoked
    thread_id_pending_class uuid, -- thread_priority with NULL priority_id
    thread_id_regrant uuid,       -- revoke then un-revoke
    priority_id uuid
);

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_user_contact uuid;
    v_priority uuid;
    v_t_no_tp uuid := gen_random_uuid();
    v_t_after uuid := gen_random_uuid();
    v_t_revoked uuid := gen_random_uuid();
    v_t_pending_class uuid := gen_random_uuid();
    v_t_regrant uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'race@test.local');
    v_user_contact := public.upsert_user_contact(v_user, 'race@test.local', 'Racer', NULL);
    SELECT id INTO v_priority FROM public.priority WHERE user_id = v_user LIMIT 1;

    -- Raw thread inserts. file_thread_priority_peers will not file the
    -- author here (contacts excludes the author by user_contact_ids),
    -- so each test thread starts with no thread_priority for v_user
    -- unless we explicitly insert one. That's exactly the race shape.
    INSERT INTO public.thread (id, created_by, title)
    VALUES (v_t_no_tp,         v_user, 'no tp'),
           (v_t_after,          v_user, 'after'),
           (v_t_revoked,        v_user, 'revoked'),
           (v_t_pending_class,  v_user, 'pending class'),
           (v_t_regrant,        v_user, 'regrant');

    -- Revoked filing.
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id, revoked_at)
    VALUES (v_t_revoked, v_user, v_priority, now());

    -- Pending-classification filing (priority_id NULL, classify_at set).
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id, classify_at)
    VALUES (v_t_pending_class, v_user, NULL, now());

    -- Regrant scenario: settled filing.
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_t_regrant, v_user, v_priority);

    INSERT INTO _ids VALUES (
        v_user, v_user_contact,
        v_t_no_tp, v_t_after, v_t_revoked, v_t_pending_class, v_t_regrant,
        v_priority
    );
END $$;

-- ---------------------------------------------------------------------------
-- Case 1: push arrives BEFORE thread_priority. Must succeed (no raise) and
-- write a pending_thread_state row; thread_state remains absent.
-- ---------------------------------------------------------------------------
SELECT lives_ok(
    $$ SELECT "user".upsert_thread_state(
          (SELECT user_id FROM _ids),
          (SELECT thread_id_no_tp FROM _ids),
          TRUE,    -- p_active
          FALSE,   -- p_urgent
          50::smallint,
          NULL,    -- p_read_at
          NULL,    -- p_bumped_at
          NULL,    -- p_note_created_at
          NULL, NULL, NULL,
          TRUE,    -- p_set_active
          FALSE, FALSE, FALSE, FALSE, FALSE, FALSE
       ) $$,
    'case 1: upsert_thread_state without thread_priority does not raise'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM thread_state ts, _ids
         WHERE ts.user_id = _ids.user_id AND ts.thread_id = _ids.thread_id_no_tp
    ),
    'case 1: no thread_state row was written'
) FROM _ids LIMIT 1;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pending_thread_state pts, _ids
         WHERE pts.user_id = _ids.user_id AND pts.thread_id = _ids.thread_id_no_tp
           AND (pts.payload ->> 'p_active')::boolean = TRUE
           AND (pts.payload ->> 'p_set_active')::boolean = TRUE
    ),
    'case 1: pending_thread_state row carries the payload'
) FROM _ids LIMIT 1;

-- ---------------------------------------------------------------------------
-- Case 2: insert thread_priority. Trigger must flush pending row and apply
-- thread_state. Pending row must be deleted.
--
-- Use the "after" thread (not no_tp) so we can compare per-case.
-- ---------------------------------------------------------------------------
-- First, defer a push for v_t_after.
SELECT "user".upsert_thread_state(
    (SELECT user_id FROM _ids),
    (SELECT thread_id_after FROM _ids),
    TRUE, FALSE, 50::smallint,
    NULL, NULL, NULL, NULL, NULL, NULL,
    TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pending_thread_state pts, _ids
         WHERE pts.user_id = _ids.user_id AND pts.thread_id = _ids.thread_id_after
    ),
    'case 2 setup: pending row present before thread_priority insert'
) FROM _ids LIMIT 1;

-- Now insert thread_priority — trigger should flush.
INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
SELECT thread_id_after, user_id, priority_id FROM _ids;

SELECT ok(
    EXISTS (
        SELECT 1 FROM thread_state ts, _ids
         WHERE ts.user_id = _ids.user_id AND ts.thread_id = _ids.thread_id_after
           AND ts.active = TRUE
    ),
    'case 2: thread_state.active=true applied via trigger'
) FROM _ids LIMIT 1;

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM pending_thread_state pts, _ids
         WHERE pts.user_id = _ids.user_id AND pts.thread_id = _ids.thread_id_after
    ),
    'case 2: pending row was deleted after flush'
) FROM _ids LIMIT 1;

-- ---------------------------------------------------------------------------
-- Case 3: push targets a REVOKED thread_priority. Defer; do NOT apply.
-- ---------------------------------------------------------------------------
SELECT "user".upsert_thread_state(
    (SELECT user_id FROM _ids),
    (SELECT thread_id_revoked FROM _ids),
    TRUE, FALSE, 50::smallint,
    NULL, NULL, NULL, NULL, NULL, NULL,
    TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM thread_state ts, _ids
         WHERE ts.user_id = _ids.user_id AND ts.thread_id = _ids.thread_id_revoked
    ),
    'case 3: thread_state NOT written when thread_priority is revoked'
) FROM _ids LIMIT 1;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pending_thread_state pts, _ids
         WHERE pts.user_id = _ids.user_id AND pts.thread_id = _ids.thread_id_revoked
    ),
    'case 3: pending row stays put for revoked thread_priority'
) FROM _ids LIMIT 1;

-- ---------------------------------------------------------------------------
-- Case 4: thread_priority exists but priority_id is NULL (pending
-- classification). Defer; do NOT apply.
-- ---------------------------------------------------------------------------
SELECT "user".upsert_thread_state(
    (SELECT user_id FROM _ids),
    (SELECT thread_id_pending_class FROM _ids),
    TRUE, FALSE, 50::smallint,
    NULL, NULL, NULL, NULL, NULL, NULL,
    TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE
);

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM thread_state ts, _ids
         WHERE ts.user_id = _ids.user_id AND ts.thread_id = _ids.thread_id_pending_class
    ),
    'case 4: thread_state NOT written when priority_id is NULL'
) FROM _ids LIMIT 1;

SELECT ok(
    EXISTS (
        SELECT 1 FROM pending_thread_state pts, _ids
         WHERE pts.user_id = _ids.user_id AND pts.thread_id = _ids.thread_id_pending_class
    ),
    'case 4: pending row stays put while classification pends'
) FROM _ids LIMIT 1;

-- ---------------------------------------------------------------------------
-- Case 5: second push for same (user, thread) before flush. Payload
-- overwrites. Apply the latest after thread_priority lands.
-- ---------------------------------------------------------------------------
-- First push: active=true, importance unset.
SELECT "user".upsert_thread_state(
    (SELECT user_id FROM _ids),
    (SELECT thread_id_no_tp FROM _ids),
    TRUE, FALSE, 50::smallint,
    NULL, NULL, NULL, NULL, NULL, NULL,
    TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE
);
-- Second push: active=true AND importance=75.
SELECT "user".upsert_thread_state(
    (SELECT user_id FROM _ids),
    (SELECT thread_id_no_tp FROM _ids),
    TRUE, FALSE, 75::smallint,
    NULL, NULL, NULL, NULL, NULL, NULL,
    TRUE, FALSE, TRUE, FALSE, FALSE, FALSE, FALSE
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pending_thread_state pts, _ids
         WHERE pts.user_id = _ids.user_id AND pts.thread_id = _ids.thread_id_no_tp
           AND (pts.payload ->> 'p_importance')::int = 75
           AND (pts.payload ->> 'p_set_importance')::boolean = TRUE
    ),
    'case 5: latest payload overwrote earlier pending row'
) FROM _ids LIMIT 1;

-- Flush via thread_priority insert.
INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
SELECT thread_id_no_tp, user_id, priority_id FROM _ids;

SELECT ok(
    EXISTS (
        SELECT 1 FROM thread_state ts, _ids
         WHERE ts.user_id = _ids.user_id AND ts.thread_id = _ids.thread_id_no_tp
           AND ts.active = TRUE AND ts.importance = 75
    ),
    'case 5: applied state reflects the LATEST pending payload'
) FROM _ids LIMIT 1;

-- ---------------------------------------------------------------------------
-- Case 6: re-grant flushes pending. Revoke the regrant thread's filing,
-- push state (deferred), then clear revoked_at — the trigger must fire
-- on the revoked_at transition and apply.
-- ---------------------------------------------------------------------------
UPDATE public.thread_priority
   SET revoked_at = now()
 WHERE thread_id = (SELECT thread_id_regrant FROM _ids)
   AND user_id   = (SELECT user_id           FROM _ids);

SELECT "user".upsert_thread_state(
    (SELECT user_id FROM _ids),
    (SELECT thread_id_regrant FROM _ids),
    TRUE, FALSE, 50::smallint,
    NULL, NULL, NULL, NULL, NULL, NULL,
    TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE
);

SELECT ok(
    EXISTS (
        SELECT 1 FROM pending_thread_state pts, _ids
         WHERE pts.user_id = _ids.user_id AND pts.thread_id = _ids.thread_id_regrant
    ),
    'case 6 setup: pending row written while revoked'
) FROM _ids LIMIT 1;

UPDATE public.thread_priority
   SET revoked_at = NULL
 WHERE thread_id = (SELECT thread_id_regrant FROM _ids)
   AND user_id   = (SELECT user_id           FROM _ids);

SELECT ok(
    EXISTS (
        SELECT 1 FROM thread_state ts, _ids
         WHERE ts.user_id = _ids.user_id AND ts.thread_id = _ids.thread_id_regrant
           AND ts.active = TRUE
    ),
    'case 6: re-grant flushes pending into thread_state'
) FROM _ids LIMIT 1;

SELECT * FROM finish();
ROLLBACK;
