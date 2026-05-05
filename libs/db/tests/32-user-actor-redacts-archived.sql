BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(8);

CREATE TEMP TABLE _ids (
    andrew_id uuid,
    andrew_c uuid,
    andrew_alt uuid,
    victim_id uuid,
    victim_c uuid
);

DO $$
DECLARE
    v_andrew uuid := gen_random_uuid();
    v_andrew_c uuid;
    v_andrew_alt uuid := gen_random_uuid();
    v_victim uuid := gen_random_uuid();
    v_victim_c uuid;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_andrew, 'andrew@t.l'),
        (v_victim, 'victim@t.l');

    v_andrew_c := public.upsert_user_contact(v_andrew, 'andrew@t.l', 'Andrew K.', 'http://a/p.png');
    v_victim_c := public.upsert_user_contact(v_victim, 'victim@t.l', 'Victim',    NULL);

    -- Add a non-primary identity for Andrew so we exercise the second clause too.
    INSERT INTO public.contact (id, email, name, user_id, "primary")
    VALUES (v_andrew_alt, 'andrew-alt@t.l', 'Andrew Alt', v_andrew, false);

    -- Simulate the historical leak: victim has an unarchived user_contact pointing at Andrew.
    INSERT INTO user_contact (user_id, contact_id, linked, source)
    VALUES (v_victim, v_andrew_c, false, 'thread');

    INSERT INTO _ids VALUES (v_andrew, v_andrew_c, v_andrew_alt, v_victim, v_victim_c);
END $$;

-- Pre-archive: victim sees Andrew with PII intact.
SELECT ok(
    (SELECT name FROM "user".actor a, _ids WHERE a.user_id = _ids.victim_id AND a.id = _ids.andrew_c) = 'Andrew K.',
    'pre-archive: name is visible'
) FROM _ids LIMIT 1;
SELECT ok(
    (SELECT email FROM "user".actor a, _ids WHERE a.user_id = _ids.victim_id AND a.id = _ids.andrew_c) = 'andrew@t.l',
    'pre-archive: email is visible'
) FROM _ids LIMIT 1;
SELECT ok(
    (SELECT archived_at FROM "user".actor a, _ids WHERE a.user_id = _ids.victim_id AND a.id = _ids.andrew_c) IS NULL,
    'pre-archive: archived_at is null'
) FROM _ids LIMIT 1;

-- Archive the user_contact row (the act we are auditing).
UPDATE user_contact SET archived_at = now()
 WHERE user_id = (SELECT victim_id FROM _ids)
   AND contact_id = (SELECT andrew_c FROM _ids);

-- Post-archive: victim still receives the row (archived_at set), but with no PII.
SELECT ok(
    (SELECT archived_at FROM "user".actor a, _ids WHERE a.user_id = _ids.victim_id AND a.id = _ids.andrew_c) IS NOT NULL,
    'post-archive: archived_at is set'
) FROM _ids LIMIT 1;
SELECT ok(
    (SELECT name IS NULL AND email IS NULL AND avatar_url IS NULL
       FROM "user".actor a, _ids WHERE a.user_id = _ids.victim_id AND a.id = _ids.andrew_c),
    'post-archive: name/email/avatar are redacted'
) FROM _ids LIMIT 1;

-- Non-primary identity must also redact.
SELECT ok(
    (SELECT archived_at IS NOT NULL AND name IS NULL AND email IS NULL
       FROM "user".actor a, _ids WHERE a.user_id = _ids.victim_id AND a.id = _ids.andrew_alt),
    'post-archive: non-primary identity also redacts'
) FROM _ids LIMIT 1;

-- Andrew's own self-row must remain pristine.
SELECT ok(
    EXISTS (SELECT 1 FROM "user".actor a, _ids
             WHERE a.user_id = _ids.andrew_id AND a.id = _ids.andrew_c
               AND a.name = 'Andrew K.' AND a.archived_at IS NULL),
    'andrew still sees his own contact unredacted'
) FROM _ids LIMIT 1;

-- 8th assertion: a contact archived globally (a.archived_at) must redact even
-- when the recipient's user_contact is still active. This catches the case
-- where a user deletes/suspends their account; viewers' user_contact rows are
-- not auto-bumped, but the tombstone they receive must still be PII-free.
DO $$
DECLARE
    v_carl uuid := gen_random_uuid();
    v_carl_c uuid;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_carl, 'carl@t.l');
    v_carl_c := public.upsert_user_contact(v_carl, 'carl@t.l', 'Carl', NULL);

    -- A second user with an active visibility row pointing at carl.
    INSERT INTO user_contact (user_id, contact_id, linked, source)
    VALUES ((SELECT victim_id FROM _ids), v_carl_c, false, 'thread');

    -- Globally archive carl's contact.
    UPDATE public.contact SET archived_at = now() WHERE id = v_carl_c;

    -- Stash carl_c so the assertion can reference it.
    UPDATE _ids SET andrew_alt = v_carl_c;  -- reuse alias slot
END $$;

SELECT ok(
    (SELECT archived_at IS NOT NULL AND name IS NULL AND email IS NULL AND avatar_url IS NULL
       FROM "user".actor a, _ids
      WHERE a.user_id = _ids.victim_id AND a.id = _ids.andrew_alt),
    'globally-archived contact (a.archived_at) is redacted in viewer tombstone'
) FROM _ids LIMIT 1;

SELECT * FROM finish();
ROLLBACK;
