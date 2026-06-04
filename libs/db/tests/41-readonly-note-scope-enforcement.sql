-- Read-only note scope enforcement (§2 server rule):
--   A user who reaches a thread only via an announce group (no write access)
--   may scope a reply to the thread's contacts and its non-announce groups,
--   but NOT to an announce group they do not admin. This pins that
--   upsert_note rejects an out-of-scope read-only reply.
--
-- NOTE on the upsert_note call sites below: the local positional argument
-- order is
--   user_id, p_id, p_author_id, p_created_by, p_updated_by, p_archived_at,
--   p_thread_id, p_draft, p_access_contacts, p_access_groups, p_content,
--   p_actions, p_mentions, p_re_note_id, p_source_created_at, p_key,
--   p_merged_from_thread_id
-- (see libs/db/schema/90-user-schema/85-user-sync-upserts.sql). The plan's
-- example used a different stated order; the calls here match the real one.
BEGIN;
SET LOCAL search_path = public, "user", extensions;
SELECT plan(6);

DO $$
DECLARE
    v_author      uuid := gen_random_uuid();   -- author user (Kris stand-in)
    v_viewer      uuid := gen_random_uuid();   -- read-only announce viewer
    v_author_c    uuid;
    v_viewer_c    uuid;
    v_announce    uuid := gen_random_uuid();   -- announce group (Everyone stand-in)
    v_team        uuid := gen_random_uuid();   -- non-announce group (Plot Team stand-in)
    v_thread      uuid := gen_random_uuid();
    v_root        uuid;
BEGIN
    -- Two users. public.user.email is NOT NULL; the AFTER INSERT trigger
    -- (accept_invitations_on_signup -> activate_invited_user) creates each
    -- user's root priority AND a primary linked user_contact keyed on their
    -- email. Reuse that auto-created primary contact as each user's contact
    -- (matching the pattern in 30-announce-group-contact-isolation.sql), so
    -- we don't collide with the one-primary-per-user unique index.
    INSERT INTO "user" (id, email) VALUES
        (v_author, 'author@test.local'), (v_viewer, 'viewer@test.local');
    SELECT contact_id INTO v_author_c FROM user_contact
        WHERE user_id = v_author AND "primary" = TRUE AND linked = TRUE LIMIT 1;
    SELECT contact_id INTO v_viewer_c FROM user_contact
        WHERE user_id = v_viewer AND "primary" = TRUE AND linked = TRUE LIMIT 1;
    SELECT id INTO v_root FROM priority WHERE user_id = v_viewer AND nlevel(path) = 1 LIMIT 1;

    -- Groups: announce (no admins) + team (viewer is NOT a member).
    INSERT INTO "group" (id, name, type, created_by) VALUES
        (v_announce, 'Everyone', 'announce', v_author),
        (v_team, 'Plot Team', 'team', v_author);
    -- Author + viewer are members of the announce group; author is also team member.
    INSERT INTO group_member (group_id, contact_id) VALUES
        (v_announce, v_author_c), (v_announce, v_viewer_c), (v_team, v_author_c);

    -- Thread authored by author, addressed to [team, announce], contacts [author].
    INSERT INTO thread (id, created_by, title, contacts, groups)
        VALUES (v_thread, v_author, 'Welcome', ARRAY[v_author_c], ARRAY[v_team, v_announce]);
    -- Ensure the viewer has a SETTLED thread_priority filing. The thread
    -- INSERT already filed the viewer via announce membership, but with
    -- priority_id = NULL (pending classification); upsert_note treats a
    -- NULL priority_id as "Thread not found", so settle it here.
    INSERT INTO thread_priority (thread_id, user_id, priority_id)
        VALUES (v_thread, v_viewer, v_root)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET priority_id = EXCLUDED.priority_id, classify_at = NULL;

    PERFORM set_config('test.viewer', v_viewer::text, false);
    PERFORM set_config('test.thread', v_thread::text, false);
    PERFORM set_config('test.team', v_team::text, false);
    PERFORM set_config('test.announce', v_announce::text, false);
    PERFORM set_config('test.author_c', v_author_c::text, false);
END $$;

-- 1. The viewer is a read-only viewer of this thread.
SELECT is(
    "user".user_has_thread_write_access(
        current_setting('test.viewer')::uuid,
        current_setting('test.thread')::uuid),
    FALSE, 'viewer has no write access');

-- 2. Scoping a reply to the team group (a non-announce thread group) is allowed,
--    AND the scope is actually stored on the created note (regression guard).
SELECT lives_ok($$
    SELECT "user".upsert_note(
        current_setting('test.viewer')::uuid,  -- user_id
        NULL, NULL, NULL, 0, NULL,             -- p_id, p_author_id, p_created_by, p_updated_by, p_archived_at
        current_setting('test.thread')::uuid,  -- p_thread_id
        FALSE,                                 -- p_draft
        NULL,                                  -- p_access_contacts
        ARRAY[current_setting('test.team')::uuid],  -- p_access_groups (team)
        'reply to plot team',                  -- p_content
        NULL, NULL, NULL, now(), NULL)         -- p_actions, p_mentions, p_re_note_id, p_source_created_at, p_key
$$, 'reply scoped to non-announce team group is accepted');

SELECT ok(
    (SELECT (r).access_groups IS NOT NULL FROM (
        SELECT "user".upsert_note(
            current_setting('test.viewer')::uuid,
            NULL, NULL, NULL, 0, NULL,
            current_setting('test.thread')::uuid,
            FALSE,
            NULL,
            ARRAY[current_setting('test.team')::uuid],
            'reply to plot team (stored?)',
            NULL, NULL, NULL, now(), NULL) AS r) s),
    'scoped-to-team note stores access_groups');

-- 3. Scoping a reply to a thread contact (the author) is allowed, AND the
--    scope is actually stored on the created note (regression guard).
SELECT lives_ok($$
    SELECT "user".upsert_note(
        current_setting('test.viewer')::uuid,
        NULL, NULL, NULL, 0, NULL,
        current_setting('test.thread')::uuid,
        FALSE,
        ARRAY[current_setting('test.author_c')::uuid],  -- p_access_contacts (author)
        NULL,                                  -- p_access_groups
        'reply to author',
        NULL, NULL, NULL, now(), NULL)
$$, 'reply scoped to a thread contact is accepted');

SELECT ok(
    (SELECT (r).access_contacts IS NOT NULL FROM (
        SELECT "user".upsert_note(
            current_setting('test.viewer')::uuid,
            NULL, NULL, NULL, 0, NULL,
            current_setting('test.thread')::uuid,
            FALSE,
            ARRAY[current_setting('test.author_c')::uuid],
            NULL,
            'reply to author (stored?)',
            NULL, NULL, NULL, now(), NULL) AS r) s),
    'scoped-to-contact note stores access_contacts');

-- 4. Scoping a reply to the announce group (not an admin) is rejected.
SELECT throws_ok($$
    SELECT "user".upsert_note(
        current_setting('test.viewer')::uuid,
        NULL, NULL, NULL, 0, NULL,
        current_setting('test.thread')::uuid,
        FALSE,
        NULL,                                  -- p_access_contacts
        ARRAY[current_setting('test.announce')::uuid],  -- p_access_groups (announce!)
        'broadcast back',
        NULL, NULL, NULL, now(), NULL)
$$, NULL, 'read-only viewer cannot scope a note to an announce group');

SELECT * FROM finish();
ROLLBACK;
