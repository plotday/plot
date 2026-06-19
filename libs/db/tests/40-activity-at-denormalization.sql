-- Feed activity_at denormalization.
--
-- Covers the write-maintained feed sort key:
--   thread.activity_base  = GREATEST(last_note_source_created_at,
--                                    MAX(link.source_created_at),
--                                    latest past schedule end, created_at)
--   thread_priority.activity_at = GREATEST(thread.activity_base, thread_state.bumped_at)
-- plus the transaction-local seq-suppression flag (plot.skip_activity_seq) that
-- keeps these activity-only writes from advancing the sync cursor (the app
-- strips activity_at and recomputes ordering locally).
--
-- NOTE on seq testing: within one transaction now()/pg_current_xact_id() are
-- constants, so a "bumped" seq is indistinguishable from the insert seq. To
-- observe preservation we plant a sentinel seq ('1'::xid8) via a briefly
-- disabled trigger, then check whether an update keeps or replaces it.
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(19);

-- ── Task 1: plot.skip_activity_seq preserves seq on UPDATE ──────────────────
CREATE TEMP TABLE _sk (seq_after_skip xid8, seq_after_normal xid8);

DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    v_thread uuid := gen_random_uuid();
    v_skip   xid8;
    v_normal xid8;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'skipflag@t.l');
    INSERT INTO public.thread (id, created_by, draft) VALUES (v_thread, v_user, TRUE);

    -- Plant a sentinel seq distinct from the current xact id (bypass trigger).
    ALTER TABLE public.thread DISABLE TRIGGER set_thread_updated_at;
    UPDATE public.thread SET seq = '1'::xid8 WHERE id = v_thread;
    ALTER TABLE public.thread ENABLE TRIGGER set_thread_updated_at;

    -- Skip flag ON: an update preserves the sentinel seq.
    PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
    UPDATE public.thread SET preview = 'x' WHERE id = v_thread;
    PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);
    SELECT seq INTO v_skip FROM public.thread WHERE id = v_thread;

    -- Skip flag OFF: an update bumps seq off the sentinel.
    UPDATE public.thread SET preview = 'y' WHERE id = v_thread;
    SELECT seq INTO v_normal FROM public.thread WHERE id = v_thread;

    INSERT INTO _sk VALUES (v_skip, v_normal);
END $$;

SELECT is((SELECT seq_after_skip FROM _sk), '1'::xid8,
    'plot.skip_activity_seq=on preserves thread.seq');
SELECT isnt((SELECT seq_after_normal FROM _sk), '1'::xid8,
    'normal update bumps thread.seq off the sentinel');

-- ── Task 2: thread.activity_base maintained by note changes ─────────────────
-- Unscoped note advances activity_base to its source_created_at; a later scoped
-- note (access_contacts set) must NOT touch the shared activity_base (it would
-- reorder the thread for users who can't see the private reply).
CREATE TEMP TABLE _t2 (t1 timestamptz, base_after_unscoped timestamptz, base_after_scoped timestamptz);

DO $$
DECLARE
    v_user    uuid := gen_random_uuid();
    v_contact uuid;
    v_thread  uuid := gen_random_uuid();
    v_t1      timestamptz := now() + interval '1 hour';
    v_t2      timestamptz := now() + interval '2 hours';
    v_base1   timestamptz;
    v_base2   timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'note-base@t.l');
    v_contact := public.upsert_user_contact(v_user, 'note-base@t.l', 'Author', NULL);
    INSERT INTO public.thread (id, created_by, title) VALUES (v_thread, v_user, 'T');

    -- Unscoped note (access_contacts/groups NULL) → bumps shared activity_base.
    INSERT INTO public.note (thread_id, author_id, created_by, content, source_created_at, draft)
    VALUES (v_thread, v_contact, v_user, 'hi', v_t1, FALSE);
    SELECT activity_base INTO v_base1 FROM public.thread WHERE id = v_thread;

    -- Scoped note (access_contacts non-null) → must NOT touch activity_base.
    INSERT INTO public.note (thread_id, author_id, created_by, content, source_created_at, draft, access_contacts)
    VALUES (v_thread, v_contact, v_user, 'private', v_t2, FALSE, ARRAY[v_contact]);
    SELECT activity_base INTO v_base2 FROM public.thread WHERE id = v_thread;

    INSERT INTO _t2 VALUES (v_t1, v_base1, v_base2);
END $$;

SELECT is((SELECT base_after_unscoped FROM _t2), (SELECT t1 FROM _t2),
    'unscoped note sets thread.activity_base to its source_created_at');
SELECT is((SELECT base_after_scoped FROM _t2), (SELECT t1 FROM _t2),
    'scoped note does NOT change shared thread.activity_base');

-- ── Task 3: link source_created_at maintains activity_base (seq-suppressed) ──
CREATE TEMP TABLE _t3 (t3 timestamptz, base_after_link timestamptz, seq_after_link xid8);

DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    v_thread uuid := gen_random_uuid();
    v_t3     timestamptz := now() + interval '3 hours';
    v_base   timestamptz;
    v_seq    xid8;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'link-base@t.l');
    INSERT INTO public.thread (id, created_by, title) VALUES (v_thread, v_user, 'T');

    -- Plant a sentinel seq so we can observe seq-suppression in one transaction.
    ALTER TABLE public.thread DISABLE TRIGGER set_thread_updated_at;
    UPDATE public.thread SET seq = '1'::xid8 WHERE id = v_thread;
    ALTER TABLE public.thread ENABLE TRIGGER set_thread_updated_at;

    INSERT INTO public.link (thread_id, source_created_at) VALUES (v_thread, v_t3);
    SELECT activity_base, seq INTO v_base, v_seq FROM public.thread WHERE id = v_thread;
    INSERT INTO _t3 VALUES (v_t3, v_base, v_seq);
END $$;

SELECT is((SELECT base_after_link FROM _t3), (SELECT t3 FROM _t3),
    'link source_created_at advances thread.activity_base');
SELECT is((SELECT seq_after_link FROM _t3), '1'::xid8,
    'link activity_base maintenance is seq-suppressed (thread.seq preserved)');

-- ── Task 4: schedule maintains activity_base for PAST event ends only ───────
-- A non-recurring base schedule whose end is already in the past folds into
-- activity_base. Future ends (client owns the live "just ended" transition) and
-- recurring schedules do not.
CREATE TEMP TABLE _t4 (past_end timestamptz, base_past timestamptz, base_future timestamptz, base_recurring timestamptz);

DO $$
DECLARE
    v_user       uuid := gen_random_uuid();
    v_thr_past   uuid := gen_random_uuid();
    v_thr_future uuid := gen_random_uuid();
    v_thr_rec    uuid := gen_random_uuid();
    v_past_end   timestamptz := now() - interval '1 day';
    v_bp timestamptz; v_bf timestamptz; v_br timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'sched-base@t.l');
    INSERT INTO public.thread (id, created_by, title) VALUES
        (v_thr_past, v_user, 'P'), (v_thr_future, v_user, 'F'), (v_thr_rec, v_user, 'R');
    -- Age the past thread so the past event end is AFTER its created_at.
    UPDATE public.thread SET created_at = now() - interval '10 days' WHERE id = v_thr_past;

    -- Past non-recurring base schedule → folds its end into activity_base.
    INSERT INTO public.schedule (thread_id, at)
    VALUES (v_thr_past, tstzrange(now() - interval '2 days', v_past_end));
    SELECT activity_base INTO v_bp FROM public.thread WHERE id = v_thr_past;

    -- Future end → ignored (client owns the live transition).
    INSERT INTO public.schedule (thread_id, at)
    VALUES (v_thr_future, tstzrange(now() + interval '1 day', now() + interval '2 days'));
    SELECT activity_base INTO v_bf FROM public.thread WHERE id = v_thr_future;

    -- Recurring (even with a past end) → ignored.
    INSERT INTO public.schedule (thread_id, at, recurrence_rule, duration)
    VALUES (v_thr_rec, tstzrange(now() - interval '2 days', now() - interval '1 day'),
            'FREQ=DAILY', interval '1 hour');
    SELECT activity_base INTO v_br FROM public.thread WHERE id = v_thr_rec;

    INSERT INTO _t4 VALUES (v_past_end, v_bp, v_bf, v_br);
END $$;

SELECT is((SELECT base_past FROM _t4), (SELECT past_end FROM _t4),
    'past non-recurring event end folds into thread.activity_base');
SELECT ok((SELECT base_future FROM _t4) IS NULL,
    'future event end does NOT fold into activity_base');
SELECT ok((SELECT base_recurring FROM _t4) IS NULL,
    'recurring schedule does NOT fold into activity_base');

-- ── Task 5: thread_priority.activity_at = GREATEST(activity_base, bumped_at) ──

-- (5a) Seed on INSERT from the thread's current activity_base.
CREATE TEMP TABLE _t5a (base timestamptz, seeded timestamptz);
DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_contact uuid;
    v_thread uuid := gen_random_uuid();
    v_t timestamptz := now() + interval '4 hours';
    v_base timestamptz; v_seeded timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 't5a@t.l');
    v_contact := public.upsert_user_contact(v_user, 't5a@t.l', 'A', NULL);
    INSERT INTO public.thread (id, created_by, title) VALUES (v_thread, v_user, 'T');
    INSERT INTO public.note (thread_id, author_id, created_by, content, source_created_at)
    VALUES (v_thread, v_contact, v_user, 'n', v_t);
    SELECT activity_base INTO v_base FROM public.thread WHERE id = v_thread;
    -- Raw tp insert (classify_at satisfies the state-valid CHECK).
    INSERT INTO public.thread_priority (thread_id, user_id, classify_at)
    VALUES (v_thread, v_user, now());
    SELECT activity_at INTO v_seeded FROM public.thread_priority
        WHERE thread_id = v_thread AND user_id = v_user;
    INSERT INTO _t5a VALUES (v_base, v_seeded);
END $$;
SELECT is((SELECT seeded FROM _t5a), (SELECT base FROM _t5a),
    'thread_priority.activity_at seeds from thread.activity_base on insert');

-- (5b) Unscoped note fans activity_at to ALL filed users, seq-suppressed.
CREATE TEMP TABLE _t5b (t timestamptz, u1_at timestamptz, u2_at timestamptz, u1_seq xid8);
DO $$
DECLARE
    v_a uuid := gen_random_uuid(); v_b uuid := gen_random_uuid();
    v_ac uuid; v_thread uuid := gen_random_uuid();
    v_t timestamptz := now() + interval '5 hours';
    v_u1 timestamptz; v_u2 timestamptz; v_seq xid8;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_a, 't5b-a@t.l'), (v_b, 't5b-b@t.l');
    v_ac := public.upsert_user_contact(v_a, 't5b-a@t.l', 'A', NULL);
    INSERT INTO public.thread (id, created_by, title) VALUES (v_thread, v_a, 'T');
    INSERT INTO public.thread_priority (thread_id, user_id, classify_at) VALUES
        (v_thread, v_a, now()), (v_thread, v_b, now());
    -- Plant sentinel seq on both tp rows.
    ALTER TABLE public.thread_priority DISABLE TRIGGER set_thread_priority_updated_at;
    UPDATE public.thread_priority SET seq = '1'::xid8 WHERE thread_id = v_thread;
    ALTER TABLE public.thread_priority ENABLE TRIGGER set_thread_priority_updated_at;
    -- Unscoped note bumps thread.activity_base → fan-out to both tp rows.
    INSERT INTO public.note (thread_id, author_id, created_by, content, source_created_at)
    VALUES (v_thread, v_ac, v_a, 'n', v_t);
    SELECT activity_at INTO v_u1 FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_a;
    SELECT activity_at INTO v_u2 FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_b;
    SELECT seq INTO v_seq FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_a;
    INSERT INTO _t5b VALUES (v_t, v_u1, v_u2, v_seq);
END $$;
SELECT is((SELECT u1_at FROM _t5b), (SELECT t FROM _t5b), 'unscoped note advances filed user 1 activity_at');
SELECT is((SELECT u2_at FROM _t5b), (SELECT t FROM _t5b), 'unscoped note advances filed user 2 activity_at (full fan-out)');
SELECT is((SELECT u1_seq FROM _t5b), '1'::xid8, 'activity_at fan-out is seq-suppressed (thread_priority.seq preserved)');

-- (5c) Scoped note advances ONLY the visible user's activity_at.
CREATE TEMP TABLE _t5c (now_ts timestamptz, aged timestamptz, vis_at timestamptz, hid_at timestamptz);
DO $$
DECLARE
    v_author uuid := gen_random_uuid(); v_hidden uuid := gen_random_uuid();
    v_ac uuid; v_thread uuid := gen_random_uuid();
    v_now timestamptz := now(); v_aged timestamptz := now() - interval '10 days';
    v_vis timestamptz; v_hid timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_author, 't5c-au@t.l'), (v_hidden, 't5c-hi@t.l');
    v_ac := public.upsert_user_contact(v_author, 't5c-au@t.l', 'Au', NULL);
    INSERT INTO public.thread (id, created_by, title) VALUES (v_thread, v_author, 'T');
    UPDATE public.thread SET created_at = v_aged WHERE id = v_thread;  -- seed tp at the aged time
    INSERT INTO public.thread_priority (thread_id, user_id, classify_at) VALUES
        (v_thread, v_author, now()), (v_thread, v_hidden, now());
    -- Scoped note visible only to the author (access_contacts = author's contact).
    INSERT INTO public.note (thread_id, author_id, created_by, content, source_created_at, access_contacts)
    VALUES (v_thread, v_ac, v_author, 'private', v_now, ARRAY[v_ac]);
    SELECT activity_at INTO v_vis FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_author;
    SELECT activity_at INTO v_hid FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_hidden;
    INSERT INTO _t5c VALUES (v_now, v_aged, v_vis, v_hid);
END $$;
SELECT is((SELECT vis_at FROM _t5c), (SELECT now_ts FROM _t5c), 'scoped note advances the visible user activity_at (via bumped_at)');
SELECT is((SELECT hid_at FROM _t5c), (SELECT aged FROM _t5c), 'scoped note leaves the non-visible user activity_at unchanged');

-- (5d) Link change also fans activity_at to filed users (activity_base path).
CREATE TEMP TABLE _t5d (t timestamptz, at_after timestamptz);
DO $$
DECLARE
    v_user uuid := gen_random_uuid(); v_thread uuid := gen_random_uuid();
    v_t timestamptz := now() + interval '6 hours'; v_at timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 't5d@t.l');
    INSERT INTO public.thread (id, created_by, title) VALUES (v_thread, v_user, 'T');
    INSERT INTO public.thread_priority (thread_id, user_id, classify_at) VALUES (v_thread, v_user, now());
    INSERT INTO public.link (thread_id, source_created_at) VALUES (v_thread, v_t);
    SELECT activity_at INTO v_at FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_user;
    INSERT INTO _t5d VALUES (v_t, v_at);
END $$;
SELECT is((SELECT at_after FROM _t5d), (SELECT t FROM _t5d),
    'link source_created_at fans through to thread_priority.activity_at');

-- ── Task 6: user.thread reads tp.activity_at (parity + feed ordering) ───────
-- (6a) Parity: the view's activity_at equals GREATEST over the primitives that
-- feed it (note source time, link source time, user bump) — i.e. tp.activity_at.
CREATE TEMP TABLE _t6 (expected timestamptz, view_at timestamptz);
DO $$
DECLARE
    v_user uuid := gen_random_uuid(); v_contact uuid; v_thread uuid := gen_random_uuid();
    v_pri uuid;
    v_note timestamptz := now() + interval '1 hour';
    v_link timestamptz := now() + interval '2 hours';
    v_bump timestamptz := now() + interval '3 hours';
    v_view timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 't6@t.l');
    v_contact := public.upsert_user_contact(v_user, 't6@t.l', 'U', NULL);
    SELECT id INTO v_pri FROM public.priority WHERE user_id = v_user LIMIT 1;
    INSERT INTO public.thread (id, created_by, title, contacts)
    VALUES (v_thread, v_user, 'T', ARRAY[v_contact]);
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_thread, v_user, v_pri);
    INSERT INTO public.note (thread_id, author_id, created_by, content, source_created_at)
    VALUES (v_thread, v_contact, v_user, 'n', v_note);
    INSERT INTO public.link (thread_id, source_created_at) VALUES (v_thread, v_link);
    INSERT INTO public.thread_state (user_id, thread_id, bumped_at)
    VALUES (v_user, v_thread, v_bump);
    SELECT activity_at INTO v_view FROM "user".thread WHERE user_id = v_user AND id = v_thread;
    INSERT INTO _t6 VALUES (GREATEST(v_note, v_link, v_bump), v_view);
END $$;
SELECT is((SELECT view_at FROM _t6), (SELECT expected FROM _t6),
    'user.thread.activity_at = GREATEST(note, link, bump) via tp.activity_at');

-- (6b) Feed ordering: `activity_at < now() ORDER BY activity_at DESC LIMIT k`
-- returns the most-recent threads in order (the access pattern the index serves).
CREATE TEMP TABLE _t6b (first_id uuid, second_id uuid, want_first uuid, want_second uuid);
DO $$
DECLARE
    v_user uuid := gen_random_uuid(); v_contact uuid; v_pri uuid;
    v_old uuid := gen_random_uuid(); v_mid uuid := gen_random_uuid(); v_new uuid := gen_random_uuid();
    r_first uuid; r_second uuid;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 't6b@t.l');
    v_contact := public.upsert_user_contact(v_user, 't6b@t.l', 'U', NULL);
    SELECT id INTO v_pri FROM public.priority WHERE user_id = v_user LIMIT 1;
    INSERT INTO public.thread (id, created_by, title, contacts) VALUES
        (v_old, v_user, 'old', ARRAY[v_contact]),
        (v_mid, v_user, 'mid', ARRAY[v_contact]),
        (v_new, v_user, 'new', ARRAY[v_contact]);
    -- File with explicit past activity_at (skip-suppressed so seq isn't churned).
    PERFORM set_config('plot.skip_activity_seq', 'on', TRUE);
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id, activity_at) VALUES
        (v_old, v_user, v_pri, now() - interval '3 days'),
        (v_mid, v_user, v_pri, now() - interval '2 days'),
        (v_new, v_user, v_pri, now() - interval '1 day');
    PERFORM set_config('plot.skip_activity_seq', 'off', TRUE);

    -- Scope to our three threads (user creation seeds onboarding threads too).
    SELECT id INTO r_first FROM "user".thread
        WHERE user_id = v_user AND archived_at IS NULL AND activity_at < now()
          AND id = ANY (ARRAY[v_old, v_mid, v_new])
        ORDER BY activity_at DESC, id DESC LIMIT 1;
    SELECT id INTO r_second FROM "user".thread
        WHERE user_id = v_user AND archived_at IS NULL AND activity_at < now()
          AND id = ANY (ARRAY[v_old, v_mid, v_new])
        ORDER BY activity_at DESC, id DESC OFFSET 1 LIMIT 1;
    INSERT INTO _t6b VALUES (r_first, r_second, v_new, v_mid);
END $$;
SELECT is((SELECT first_id FROM _t6b), (SELECT want_first FROM _t6b),
    'feed orders newest activity_at first');
SELECT is((SELECT second_id FROM _t6b), (SELECT want_second FROM _t6b),
    'feed orders second-newest activity_at next');

SELECT * FROM finish();
ROLLBACK;
