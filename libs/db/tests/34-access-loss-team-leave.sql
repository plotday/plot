-- Access-loss via team_user archive (user leaves a team):
--   • team_user_revoke_team_threads must set thread_priority.revoked_at on
--     every thread scoped to the team (thread.team_id) for the leaving user,
--     except threads where the leaver is an external (customer) contact.
--   • user.thread stops emitting; user.thread_redacted emits the stub.
-- Team scope now lives solely on thread.team_id (priority.team_id is gone),
-- so there are no per-team priorities to set up.
-- See libs/db/AGENTS.md "Handling Access Loss to Synced Entities".
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(5);

CREATE TEMP TABLE _ids (
    owner_id uuid,
    leaver_id uuid,
    team_id bigint,
    thread_id uuid
);

DO $$
DECLARE
    v_owner uuid := gen_random_uuid();
    v_leaver uuid := gen_random_uuid();
    v_owner_c uuid;
    v_leaver_c uuid;
    v_team bigint;
    v_thread uuid := gen_random_uuid();
    v_owner_root uuid;
    v_leaver_root uuid;
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES
        (v_owner, 'owner34@test.local'),
        (v_leaver, 'leaver34@test.local');

    v_owner_c := public.upsert_user_contact(v_owner, 'owner34@test.local', 'Owner', NULL);
    v_leaver_c := public.upsert_user_contact(v_leaver, 'leaver34@test.local', 'Leaver', NULL);

    INSERT INTO public.team (name) VALUES ('Team 34') RETURNING id INTO v_team;
    INSERT INTO public.team_user (team_id, user_id, role) VALUES
        (v_team, v_owner, 'admin'),
        (v_team, v_leaver, 'member');

    -- Author a team-scoped thread: team_id is set explicitly (as upsert_thread
    -- does for user threads), and the leaver appears in thread.contacts so
    -- file_thread_priority_peers files their thread_priority row. Both owner
    -- and leaver are current members at insert time, so neither is recorded as
    -- external — both are gated by the team firewall (keyed on thread.team_id).
    SELECT id INTO v_owner_root FROM public.priority
      WHERE user_id = v_owner AND nlevel(path) = 1 LIMIT 1;
    SELECT id INTO v_leaver_root FROM public.priority
      WHERE user_id = v_leaver AND nlevel(path) = 1 LIMIT 1;
    INSERT INTO public.thread (id, created_by, title, preview, team_id, contacts, groups)
    VALUES (v_thread, v_owner, 'Team thread', 'team preview', v_team,
            ARRAY[v_owner_c, v_leaver_c], ARRAY[]::uuid[]);
    INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
    VALUES (v_thread, v_owner, v_owner_root)
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

    -- Settle the leaver's auto-filed pending row to their root so it's visible
    -- pre-leave (the team firewall, not pending-classification, is the gating
    -- mechanism under test).
    UPDATE public.thread_priority
       SET priority_id = v_leaver_root, classify_at = NULL
     WHERE thread_id = v_thread AND user_id = v_leaver;

    INSERT INTO _ids VALUES (v_owner, v_leaver, v_team, v_thread);
END $$;

SELECT ok(
    EXISTS (
        SELECT 1 FROM "user".thread ut, _ids
         WHERE ut.user_id = _ids.leaver_id AND ut.id = _ids.thread_id
    ),
    'pre-leave: user.thread emits the team-scoped thread for the leaver'
) FROM _ids LIMIT 1;

-- Leave the team.
UPDATE public.team_user
   SET archived_at = now()
 WHERE team_id = (SELECT team_id FROM _ids)
   AND user_id = (SELECT leaver_id FROM _ids);

SELECT ok(
    EXISTS (
        SELECT 1 FROM thread_priority tp, _ids
         WHERE tp.thread_id = _ids.thread_id AND tp.user_id = _ids.leaver_id
           AND tp.revoked_at IS NOT NULL
    ),
    'post-leave: thread_priority.revoked_at is set for team-scoped filings'
) FROM _ids LIMIT 1;

SELECT ok(
    NOT EXISTS (
        SELECT 1 FROM "user".thread ut, _ids
         WHERE ut.user_id = _ids.leaver_id AND ut.id = _ids.thread_id
    ),
    'post-leave: user.thread no longer emits the row for the leaver'
) FROM _ids LIMIT 1;

SELECT ok(
    EXISTS (
        SELECT 1 FROM "user".thread_redacted ut, _ids
         WHERE ut.user_id = _ids.leaver_id AND ut.id = _ids.thread_id
           AND ut.revoked = TRUE
           AND ut.archived_at IS NOT NULL
           AND ut.title IS NULL
    ),
    'post-leave: user.thread_redacted emits the stub'
) FROM _ids LIMIT 1;

-- Owner is unaffected — still sees the thread.
SELECT ok(
    EXISTS (
        SELECT 1 FROM "user".thread ut, _ids
         WHERE ut.user_id = _ids.owner_id AND ut.id = _ids.thread_id
           AND ut.title = 'Team thread'
    ),
    'post-leave: owner still sees the thread unchanged'
) FROM _ids LIMIT 1;

SELECT * FROM finish();
ROLLBACK;
