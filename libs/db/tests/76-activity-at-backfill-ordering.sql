-- Feed ordering for BACKFILLED content (source_created_at OLDER than the
-- thread's import/created_at). The sibling file 40-activity-at-denormalization
-- only ever uses future source times, so it never exercised the case where a
-- connector imports months of history "now": the feed sort key
-- (thread_priority.activity_at) must reflect the content's ORIGIN time, not the
-- import time, so the server order matches what the app displays.
--
-- Invariants asserted here:
--   thread.activity_base       = max content source time (note/link/past sched),
--                                NULL when there is no content (NOT created_at).
--   thread_priority.activity_at = COALESCE(GREATEST(activity_base, bumped_at),
--                                          created_at)
--     — created_at is only a FALLBACK when there is no content/bump signal, so an
--       older content time can pull activity_at BELOW the import time.
--   thread_state.bumped_at (scoped-note path) = origin source time, not now(),
--     so a backfilled private reply does not masquerade as a fresh user action.
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(10);

-- ── 1: link-only backfilled thread ─────────────────────────────────────────
-- A thread whose only content is a link imported "now" with an old
-- source_created_at must sort at the link's source time, not at import.
CREATE TEMP TABLE _l (back timestamptz, at timestamptz, base timestamptz);
DO $$
DECLARE
    v_user uuid := gen_random_uuid(); v_contact uuid; v_pri uuid;
    v_thread uuid := gen_random_uuid();
    v_back timestamptz := now() - interval '300 days';
    v_at timestamptz; v_base timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'l@t.l');
    v_contact := public.upsert_user_contact(v_user, 'l@t.l', 'L', NULL);
    SELECT id INTO v_pri FROM public.priority WHERE user_id = v_user LIMIT 1;
    INSERT INTO public.thread (id, created_by, title, contacts)
    VALUES (v_thread, v_user, 'link-only', ARRAY[v_contact]);
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_thread, v_user, v_pri);
    INSERT INTO public.link (thread_id, source_created_at) VALUES (v_thread, v_back);
    SELECT activity_at INTO v_at FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_user;
    SELECT activity_base INTO v_base FROM public.thread WHERE id = v_thread;
    INSERT INTO _l VALUES (v_back, v_at, v_base);
END $$;
SELECT is((SELECT base FROM _l), (SELECT back FROM _l),
    'link-only: activity_base = link source_created_at (not created_at)');
SELECT is((SELECT at FROM _l), (SELECT back FROM _l),
    'link-only: activity_at drops to link source time (link takes effect with no notes)');

-- ── 2: unscoped-note-only backfilled thread ─────────────────────────────────
CREATE TEMP TABLE _n (back timestamptz, at timestamptz, base timestamptz);
DO $$
DECLARE
    v_user uuid := gen_random_uuid(); v_contact uuid; v_pri uuid;
    v_thread uuid := gen_random_uuid();
    v_back timestamptz := now() - interval '200 days';
    v_at timestamptz; v_base timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'n@t.l');
    v_contact := public.upsert_user_contact(v_user, 'n@t.l', 'N', NULL);
    SELECT id INTO v_pri FROM public.priority WHERE user_id = v_user LIMIT 1;
    INSERT INTO public.thread (id, created_by, title, contacts)
    VALUES (v_thread, v_user, 'note-only', ARRAY[v_contact]);
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_thread, v_user, v_pri);
    INSERT INTO public.note (thread_id, author_id, created_by, content, source_created_at)
    VALUES (v_thread, v_contact, v_user, 'old', v_back);
    SELECT activity_at INTO v_at FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_user;
    SELECT activity_base INTO v_base FROM public.thread WHERE id = v_thread;
    INSERT INTO _n VALUES (v_back, v_at, v_base);
END $$;
SELECT is((SELECT base FROM _n), (SELECT back FROM _n),
    'unscoped-note-only: activity_base = note source (not created_at)');
SELECT is((SELECT at FROM _n), (SELECT back FROM _n),
    'unscoped-note-only: activity_at drops to note source time');

-- ── 3: scoped-note-only backfilled thread ───────────────────────────────────
-- Scoped notes never touch the shared activity_base; their origin time reaches
-- activity_at via per-user bumped_at, which must be the SOURCE time, not now().
CREATE TEMP TABLE _s (back timestamptz, at timestamptz, bump timestamptz);
DO $$
DECLARE
    v_user uuid := gen_random_uuid(); v_contact uuid; v_pri uuid;
    v_thread uuid := gen_random_uuid();
    v_back timestamptz := now() - interval '150 days';
    v_at timestamptz; v_bump timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 's@t.l');
    v_contact := public.upsert_user_contact(v_user, 's@t.l', 'S', NULL);
    SELECT id INTO v_pri FROM public.priority WHERE user_id = v_user LIMIT 1;
    INSERT INTO public.thread (id, created_by, title, contacts)
    VALUES (v_thread, v_user, 'scoped-only', ARRAY[v_contact]);
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_thread, v_user, v_pri);
    INSERT INTO public.note (thread_id, author_id, created_by, content, source_created_at, access_contacts)
    VALUES (v_thread, v_contact, v_user, 'old private', v_back, ARRAY[v_contact]);
    SELECT activity_at INTO v_at FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_user;
    SELECT bumped_at INTO v_bump FROM public.thread_state WHERE thread_id = v_thread AND user_id = v_user;
    INSERT INTO _s VALUES (v_back, v_at, v_bump);
END $$;
SELECT is((SELECT bump FROM _s), (SELECT back FROM _s),
    'scoped-only: bumped_at = note source time (not now())');
SELECT is((SELECT at FROM _s), (SELECT back FROM _s),
    'scoped-only: activity_at drops to note source time');

-- ── 4: per-message sharing — each user sorts at their latest VISIBLE message ─
-- User A sees an older private note; User B sees a newer one. Each user's
-- bumped_at / activity_at reflects only the message they can see.
CREATE TEMP TABLE _pm (a_src timestamptz, b_src timestamptz, a_at timestamptz, b_at timestamptz);
DO $$
DECLARE
    v_a uuid := gen_random_uuid(); v_b uuid := gen_random_uuid();
    v_ac uuid; v_bc uuid; v_pa uuid; v_pb uuid;
    v_thread uuid := gen_random_uuid();
    v_a_src timestamptz := now() - interval '90 days';
    v_b_src timestamptz := now() - interval '30 days';
    v_a_at timestamptz; v_b_at timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_a, 'pm-a@t.l'), (v_b, 'pm-b@t.l');
    v_ac := public.upsert_user_contact(v_a, 'pm-a@t.l', 'A', NULL);
    v_bc := public.upsert_user_contact(v_b, 'pm-b@t.l', 'B', NULL);
    SELECT id INTO v_pa FROM public.priority WHERE user_id = v_a LIMIT 1;
    SELECT id INTO v_pb FROM public.priority WHERE user_id = v_b LIMIT 1;
    INSERT INTO public.thread (id, created_by, title, contacts)
    VALUES (v_thread, v_a, 'shared', ARRAY[v_ac, v_bc]);
    -- The peer-filing trigger files B automatically; file A explicitly. Guard
    -- with ON CONFLICT so whichever row the triggers already created is kept.
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_thread, v_a, v_pa), (v_thread, v_b, v_pb)
    ON CONFLICT (thread_id, user_id) DO NOTHING;
    -- Message visible only to A (older), then a message visible only to B (newer).
    INSERT INTO public.note (thread_id, author_id, created_by, content, source_created_at, access_contacts)
    VALUES (v_thread, v_ac, v_a, 'to A', v_a_src, ARRAY[v_ac]);
    INSERT INTO public.note (thread_id, author_id, created_by, content, source_created_at, access_contacts)
    VALUES (v_thread, v_bc, v_b, 'to B', v_b_src, ARRAY[v_bc]);
    SELECT activity_at INTO v_a_at FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_a;
    SELECT activity_at INTO v_b_at FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_b;
    INSERT INTO _pm VALUES (v_a_src, v_b_src, v_a_at, v_b_at);
END $$;
SELECT is((SELECT a_at FROM _pm), (SELECT a_src FROM _pm),
    'per-message sharing: user A sorts at A''s visible message source time');
SELECT is((SELECT b_at FROM _pm), (SELECT b_src FROM _pm),
    'per-message sharing: user B sorts at B''s (newer) visible message source time');

-- ── 5: Active→Done bump still wins (app-set bumped_at = now()) ───────────────
-- Moving an old-content thread to Done sets bumped_at = now(); it must top Done
-- (activity_at = the bump), unchanged by this fix.
CREATE TEMP TABLE _d (done timestamptz, at timestamptz);
DO $$
DECLARE
    v_user uuid := gen_random_uuid(); v_contact uuid; v_pri uuid;
    v_thread uuid := gen_random_uuid();
    v_done timestamptz := now();
    v_at timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'd@t.l');
    v_contact := public.upsert_user_contact(v_user, 'd@t.l', 'D', NULL);
    SELECT id INTO v_pri FROM public.priority WHERE user_id = v_user LIMIT 1;
    INSERT INTO public.thread (id, created_by, title, contacts)
    VALUES (v_thread, v_user, 'old+done', ARRAY[v_contact]);
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_thread, v_user, v_pri);
    -- Old content.
    INSERT INTO public.link (thread_id, source_created_at) VALUES (v_thread, now() - interval '180 days');
    -- App moves it to Done: explicit bumped_at = now() (the app-owned write path).
    INSERT INTO public.thread_state (user_id, thread_id, bumped_at)
    VALUES (v_user, v_thread, v_done)
    ON CONFLICT (user_id, thread_id) DO UPDATE SET bumped_at = EXCLUDED.bumped_at;
    SELECT activity_at INTO v_at FROM public.thread_priority WHERE thread_id = v_thread AND user_id = v_user;
    INSERT INTO _d VALUES (v_done, v_at);
END $$;
SELECT is((SELECT at FROM _d), (SELECT done FROM _d),
    'Active→Done: app bumped_at=now() wins, thread tops Done');

-- ── 6: live scoped reply still re-surfaces (source ~ now) ───────────────────
CREATE TEMP TABLE _lv (live timestamptz, bump timestamptz);
DO $$
DECLARE
    v_user uuid := gen_random_uuid(); v_contact uuid; v_pri uuid;
    v_thread uuid := gen_random_uuid();
    v_live timestamptz := now();
    v_bump timestamptz;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'lv@t.l');
    v_contact := public.upsert_user_contact(v_user, 'lv@t.l', 'V', NULL);
    SELECT id INTO v_pri FROM public.priority WHERE user_id = v_user LIMIT 1;
    INSERT INTO public.thread (id, created_by, title, contacts)
    VALUES (v_thread, v_user, 'live reply', ARRAY[v_contact]);
    UPDATE public.thread SET created_at = now() - interval '60 days' WHERE id = v_thread;
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_thread, v_user, v_pri);
    INSERT INTO public.note (thread_id, author_id, created_by, content, source_created_at, access_contacts)
    VALUES (v_thread, v_contact, v_user, 'fresh private', v_live, ARRAY[v_contact]);
    SELECT bumped_at INTO v_bump FROM public.thread_state WHERE thread_id = v_thread AND user_id = v_user;
    INSERT INTO _lv VALUES (v_live, v_bump);
END $$;
SELECT is((SELECT bump FROM _lv), (SELECT live FROM _lv),
    'live scoped reply: bumped_at = now() (re-surfaces as before)');

SELECT * FROM finish();
ROLLBACK;
