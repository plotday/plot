-- End-to-end: the originating connection breaks ties between focuses with equal
-- content signal. Exact-connection match (L1) and same-org match (L2) both
-- boost; origin never hard-gates (cross-categorization stays routable).
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(5);

DO $$
DECLARE
    v_user   uuid := gen_random_uuid();
    v_user_c uuid;
    v_root   uuid;
    v_rootp  ltree;
    v_gmail  bigint;
    v_slack  bigint;
    v_c_pers uuid := gen_random_uuid();
    v_vendor uuid := gen_random_uuid();   -- shared "sender" contact = baseline con signal
    v_ti_work_gmail uuid := gen_random_uuid();
    v_ti_work_slack uuid := gen_random_uuid();
    v_ti_personal   uuid := gen_random_uuid();
    v_acme   uuid := gen_random_uuid();    -- "Acme admin" focus
    v_fin    uuid := gen_random_uuid();    -- "Personal finance" focus
    v_m_work uuid := gen_random_uuid();    -- moved example in Acme, from work gmail
    v_m_pers uuid := gen_random_uuid();    -- moved example in Finance, from personal gmail
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'me@acme.com');
    v_user_c := public.upsert_user_contact(v_user, 'me@acme.com', 'Me', NULL);
    INSERT INTO contact (id, email, name, user_id) VALUES (v_c_pers, 'me@gmail.com', 'Me Personal', v_user);
    INSERT INTO contact (id, email, name) VALUES (v_vendor, 'receipts@shop.com', 'Shop');

    SELECT id, path INTO v_root, v_rootp FROM priority WHERE user_id = v_user AND nlevel(path) = 1;

    INSERT INTO twist (twist_package_id, user_id, name, handle, version)
        VALUES (gen_random_uuid(), v_user, 'Gmail', 'gmail', '1.0') RETURNING id INTO v_gmail;
    INSERT INTO twist (twist_package_id, user_id, name, handle, version)
        VALUES (gen_random_uuid(), v_user, 'Slack', 'slack', '1.0') RETURNING id INTO v_slack;

    INSERT INTO twist_instance (id, twist_id, owner_id, name) VALUES
        (v_ti_work_gmail, v_gmail, v_user, 'Gmail'),
        (v_ti_work_slack, v_slack, v_user, 'Slack'),
        (v_ti_personal,   v_gmail, v_user, 'Gmail (personal)');
    INSERT INTO twist_instance_connection (twist_instance_id, user_id, provider, actor_id) VALUES
        (v_ti_work_gmail, v_user, 'gmail', v_user_c),
        (v_ti_work_slack, v_user, 'slack', v_user_c),
        (v_ti_personal,   v_user, 'gmail', v_c_pers);

    -- role_id required (priority_role_or_fyi CHECK); file under the user's
    -- default role created by the activate_invited_user trigger above.
    INSERT INTO priority (id, created_by, user_id, title, path, role_id) VALUES
        (v_acme, v_user, v_user, 'Acme admin',       v_rootp || 'acme',    public.default_role_id(v_user)),
        (v_fin,  v_user, v_user, 'Personal finance', v_rootp || 'finance', public.default_role_id(v_user));

    -- One moved example per focus. Both share the SAME contact (vendor) so the
    -- content (con) signal is identical for both focuses; only the originating
    -- connection differs. Connector threads: created_by = twist_instance,
    -- twist_id set.
    INSERT INTO thread (id, created_by, twist_id, title, contacts) VALUES
        (v_m_work, v_ti_work_gmail, v_gmail, 'Old work receipt',     ARRAY[v_vendor]),
        (v_m_pers, v_ti_personal,   v_gmail, 'Old personal receipt', ARRAY[v_vendor]);
    INSERT INTO thread_priority (thread_id, user_id, priority_id, user_moved) VALUES
        (v_m_work, v_user, v_acme, TRUE),
        (v_m_pers, v_user, v_fin,  TRUE);
END $$;

-- (1) A work-Gmail receipt routes to Acme admin (exact-connection L1 beats the
--     equally content-matched Personal finance).
DO $$
DECLARE v_cand uuid := gen_random_uuid(); v_u uuid := (SELECT id FROM "user" WHERE email='me@acme.com');
        v_g bigint := (SELECT id FROM twist WHERE handle='gmail' AND user_id=v_u);
        v_ti uuid := (SELECT id FROM twist_instance WHERE name='Gmail' AND owner_id=v_u);
        v_vendor uuid := (SELECT id FROM contact WHERE email='receipts@shop.com');
BEGIN
    INSERT INTO thread (id, created_by, twist_id, title, contacts)
        VALUES (v_cand, v_ti, v_g, 'New work receipt', ARRAY[v_vendor]);
END $$;
SELECT is(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='New work receipt'))),
    (SELECT id FROM priority WHERE title='Acme admin'
        AND user_id=(SELECT id FROM "user" WHERE email='me@acme.com')),
    'work-gmail receipt routes to the work focus via exact-connection match');

-- (2) A personal-Gmail receipt routes to Personal finance (symmetric).
DO $$
DECLARE v_cand uuid := gen_random_uuid(); v_u uuid := (SELECT id FROM "user" WHERE email='me@acme.com');
        v_g bigint := (SELECT id FROM twist WHERE handle='gmail' AND user_id=v_u);
        v_ti uuid := (SELECT id FROM twist_instance WHERE name='Gmail (personal)' AND owner_id=v_u);
        v_vendor uuid := (SELECT id FROM contact WHERE email='receipts@shop.com');
BEGIN
    INSERT INTO thread (id, created_by, twist_id, title, contacts)
        VALUES (v_cand, v_ti, v_g, 'New personal receipt', ARRAY[v_vendor]);
END $$;
SELECT is(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='New personal receipt'))),
    (SELECT id FROM priority WHERE title='Personal finance'
        AND user_id=(SELECT id FROM "user" WHERE email='me@acme.com')),
    'personal-gmail receipt routes to the finance focus via exact-connection match');

-- (3) Org-group transfer (L2): a work-SLACK candidate routes to Acme admin even
--     though Acme has only a work-GMAIL example — same org domain (acme.com),
--     different connection. Beats the personal-gmail-matched finance focus.
DO $$
DECLARE v_cand uuid := gen_random_uuid(); v_u uuid := (SELECT id FROM "user" WHERE email='me@acme.com');
        v_s bigint := (SELECT id FROM twist WHERE handle='slack' AND user_id=v_u);
        v_ti uuid := (SELECT id FROM twist_instance WHERE name='Slack' AND owner_id=v_u);
        v_vendor uuid := (SELECT id FROM contact WHERE email='receipts@shop.com');
BEGIN
    INSERT INTO thread (id, created_by, twist_id, title, contacts)
        VALUES (v_cand, v_ti, v_s, 'Work slack receipt', ARRAY[v_vendor]);
END $$;
SELECT is(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='Work slack receipt'))),
    (SELECT id FROM priority WHERE title='Acme admin'
        AND user_id=(SELECT id FROM "user" WHERE email='me@acme.com')),
    'work-slack receipt transfers to the work focus via same-org (domain) match');

-- (4) Soft, not a gate: a work-gmail candidate still classifies into SOME focus
--     (origin mismatch never produces a null/blocked classification).
SELECT isnt(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='New work receipt'))),
    NULL,
    'origin is soft: a classified thread always lands somewhere, never blocked');

-- (5) User-authored candidate (twist_id NULL) carries no origin signal and must
--     still classify by content without error.
DO $$
DECLARE v_cand uuid := gen_random_uuid(); v_u uuid := (SELECT id FROM "user" WHERE email='me@acme.com');
        v_vendor uuid := (SELECT id FROM contact WHERE email='receipts@shop.com');
BEGIN
    INSERT INTO thread (id, created_by, title, contacts)
        VALUES (v_cand, v_u, 'Hand-written note about shop', ARRAY[v_vendor]);
END $$;
SELECT isnt(
    (SELECT priority_id FROM public.classify_thread_for_user_explain(
        (SELECT id FROM "user" WHERE email='me@acme.com'),
        (SELECT id FROM thread WHERE title='Hand-written note about shop'))),
    NULL,
    'user-authored candidate classifies by content with no origin signal');

SELECT finish();
ROLLBACK;
