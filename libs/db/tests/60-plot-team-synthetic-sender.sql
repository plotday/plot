BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(5);

-- The synthetic "Plot Team" sender is the system Plot twist instance
-- (c_system_instance_id), seeded by 20260415202415. It authors the shared
-- onboarding / Plot Updates threads (and the per-user welcome), which every
-- user can see via the Plot Updates topic but no user owns. user.actor must
-- surface it to EVERY user so those threads resolve a sender name ("Plot Team")
-- instead of an unresolvable id — without producing a duplicate row for the
-- owner. See libs/db/schema/90-user-schema/34-actor.sql.

CREATE TEMP TABLE _t (
    sentinel uuid,
    owner_id uuid,
    stranger_id uuid
);

DO $$
DECLARE
    c_sentinel CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001';
    v_owner uuid;
    v_stranger uuid := gen_random_uuid();
BEGIN
    SELECT owner_id INTO v_owner FROM public.twist_instance WHERE id = c_sentinel;

    -- A brand-new user who does NOT own the synthetic instance.
    INSERT INTO "public"."user" (id, email) VALUES (v_stranger, 'stranger@t.l');
    PERFORM public.upsert_user_contact(v_stranger, 'stranger@t.l', 'Stranger', NULL);

    INSERT INTO _t VALUES (c_sentinel, v_owner, v_stranger);
END $$;

-- 1. The synthetic sender exists and is named "Plot Team".
SELECT is(
    (SELECT name FROM public.twist_instance WHERE id = (SELECT sentinel FROM _t)),
    'Plot Team',
    'synthetic sender is named "Plot Team"'
);

-- 2. A stranger (non-owner) resolves the synthetic sender to "Plot Team".
SELECT is(
    (SELECT name FROM "user".actor a, _t WHERE a.user_id = _t.stranger_id AND a.id = _t.sentinel),
    'Plot Team',
    'non-owner resolves the synthetic sender name'
);

-- 3. ...and it is display-only (kept out of share/mention pickers).
SELECT ok(
    (SELECT inviteable = false FROM "user".actor a, _t WHERE a.user_id = _t.stranger_id AND a.id = _t.sentinel),
    'synthetic sender is not inviteable (display-only)'
) FROM _t LIMIT 1;

-- 4. The stranger gets EXACTLY ONE row for it.
SELECT is(
    (SELECT count(*) FROM "user".actor a, _t WHERE a.user_id = _t.stranger_id AND a.id = _t.sentinel),
    1::bigint,
    'non-owner gets exactly one synthetic-sender row'
);

-- 5. The owner also gets EXACTLY ONE row — the owned-twist branch excludes the
--    sentinel so it doesn't duplicate the global synthetic-sender branch.
SELECT is(
    (SELECT count(*) FROM "user".actor a, _t WHERE a.user_id = _t.owner_id AND a.id = _t.sentinel),
    1::bigint,
    'owner gets exactly one synthetic-sender row (no duplicate)'
);

SELECT * FROM finish();
ROLLBACK;
