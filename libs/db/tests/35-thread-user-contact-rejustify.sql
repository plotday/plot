-- Re-justification: when a contact reappears on a thread the user can
-- justifiably see, sync_user_contact_for_thread_contacts must UN-ARCHIVE the
-- user_contact row that the 20260505 redact_contact_leakage sweep archived,
-- instead of leaving it tombstoned (which renders the author as "Unknown").
-- Un-archiving is gated by the SAME visibility predicate that justifies a fresh
-- row, so a user without justification keeps their redacted tombstone.
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(5);

CREATE TEMP TABLE _ids (
    viewer_id uuid,
    alice_c uuid,
    outsider_id uuid,
    thread_id uuid
);

DO $$
DECLARE
    v_viewer   uuid := gen_random_uuid();
    v_alice    uuid := gen_random_uuid();
    v_outsider uuid := gen_random_uuid();
    v_viewer_c uuid;
    v_alice_c  uuid;
    v_outsider_c uuid;
    v_thread   uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_viewer,   'viewer@t.l'),
        (v_alice,    'alice@t.l'),
        (v_outsider, 'outsider@t.l');

    v_viewer_c   := public.upsert_user_contact(v_viewer,   'viewer@t.l',   'Viewer',   NULL);
    v_alice_c    := public.upsert_user_contact(v_alice,    'alice@t.l',    'Alice',    NULL);
    v_outsider_c := public.upsert_user_contact(v_outsider, 'outsider@t.l', 'Outsider', NULL);

    -- Thread authored by viewer (justified via the author branch), with alice on
    -- it. Draft to bypass the title-required check; filing fires regardless.
    INSERT INTO public.thread (id, created_by, draft, contacts, groups)
    VALUES (v_thread, v_viewer, true, ARRAY[v_viewer_c, v_alice_c], ARRAY[]::uuid[]);

    -- Raw INSERT skips tp filing. File viewer (author → justified) and outsider
    -- (has a tp but NO justification: not the author, not on contacts, no group).
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    SELECT v_thread, v_viewer, p.id FROM public.priority p WHERE p.user_id = v_viewer LIMIT 1;
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    SELECT v_thread, v_outsider, p.id FROM public.priority p WHERE p.user_id = v_outsider LIMIT 1;

    -- Re-fire the sync trigger now that viewer's tp is in scope → files
    -- viewer→alice_c (justified, archived_at NULL).
    UPDATE public.thread SET contacts = contacts WHERE id = v_thread;

    -- Seed outsider's pre-archived leak row (what the redaction sweep produced).
    INSERT INTO user_contact (user_id, contact_id, linked, source, archived_at)
    VALUES (v_outsider, v_alice_c, false, 'thread', now())
    ON CONFLICT (user_id, contact_id) DO UPDATE SET archived_at = now();

    INSERT INTO _ids VALUES (v_viewer, v_alice_c, v_outsider, v_thread);
END $$;

-- The redaction sweep archived viewer's thread-sourced row for alice.
UPDATE user_contact SET archived_at = now()
 WHERE user_id    = (SELECT viewer_id FROM _ids)
   AND contact_id = (SELECT alice_c FROM _ids);

-- Bug state: the archived row tombstones in user.actor (name NULL == "Unknown").
SELECT ok(
    (SELECT name IS NULL AND archived_at IS NOT NULL
       FROM "user".actor a, _ids
      WHERE a.user_id = _ids.viewer_id AND a.id = _ids.alice_c),
    'before re-justification: viewer sees alice as a redacted tombstone ("Unknown")'
) FROM _ids LIMIT 1;

-- Re-fire: alice reappears on a thread viewer can justifiably see.
UPDATE public.thread SET contacts = contacts WHERE id = (SELECT thread_id FROM _ids);

-- Fix: the archived row is un-archived.
SELECT ok(
    (SELECT archived_at IS NULL
       FROM user_contact uc, _ids
      WHERE uc.user_id = _ids.viewer_id AND uc.contact_id = _ids.alice_c),
    're-justification un-archives viewer''s user_contact for alice'
) FROM _ids LIMIT 1;

-- Fix end-to-end: user.actor resolves alice's name again (no longer "Unknown").
SELECT ok(
    (SELECT name = 'Alice' AND archived_at IS NULL
       FROM "user".actor a, _ids
      WHERE a.user_id = _ids.viewer_id AND a.id = _ids.alice_c),
    're-justification restores alice''s name/identity in user.actor'
) FROM _ids LIMIT 1;

-- Guard: a user WITHOUT justification (outsider) is NOT un-archived — the
-- un-archive is gated by the same predicate that grants a fresh row.
SELECT ok(
    (SELECT archived_at IS NOT NULL
       FROM user_contact uc, _ids
      WHERE uc.user_id = _ids.outsider_id AND uc.contact_id = _ids.alice_c),
    'unjustified user''s redacted row stays archived'
) FROM _ids LIMIT 1;

-- Guard: outsider therefore still sees alice tombstoned in user.actor.
SELECT ok(
    (SELECT name IS NULL AND archived_at IS NOT NULL
       FROM "user".actor a, _ids
      WHERE a.user_id = _ids.outsider_id AND a.id = _ids.alice_c),
    'unjustified user still sees alice redacted'
) FROM _ids LIMIT 1;

SELECT * FROM finish();
ROLLBACK;
