-- connection_org_key: resolve a connection (twist_instance) to a coarse org
-- group key. Non-freemail account-email domain -> 'domain:<d>'; else owning
-- team -> 'team:<id>'; else (personal freemail, no team) -> NULL.
BEGIN;
SET LOCAL search_path = public, extensions;

SELECT plan(5);

DO $$
DECLARE
    v_user    uuid := gen_random_uuid();
    v_user_c  uuid;
    v_team    bigint;
    v_gmail   bigint;   -- twist definition id (acts as a connector)
    v_slack   bigint;
    v_c_pers  uuid := gen_random_uuid();   -- personal gmail account contact
    v_ti_work_gmail uuid := gen_random_uuid();
    v_ti_work_slack uuid := gen_random_uuid();
    v_ti_personal   uuid := gen_random_uuid();
    v_ti_team       uuid := gen_random_uuid();
BEGIN
    -- User + the user's own contact carrying their work email.
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'me@acme.com');
    v_user_c := public.upsert_user_contact(v_user, 'me@acme.com', 'Me', NULL);

    -- A personal (freemail) account contact linked to the same user.
    INSERT INTO contact (id, email, name, user_id)
        VALUES (v_c_pers, 'me@gmail.com', 'Me Personal', v_user);

    -- A team to exercise the team_id fallback.
    INSERT INTO team (name) VALUES ('Acme') RETURNING id INTO v_team;

    -- Two twist definitions to act as connectors. twist has NOT NULL
    -- twist_package_id / name / handle / version, and a twist_owner_check
    -- constraint satisfied here by setting user_id.
    INSERT INTO twist (twist_package_id, user_id, name, handle, version)
        VALUES (gen_random_uuid(), v_user, 'Gmail', 'gmail', '1.0')
        RETURNING id INTO v_gmail;
    INSERT INTO twist (twist_package_id, user_id, name, handle, version)
        VALUES (gen_random_uuid(), v_user, 'Slack', 'slack', '1.0')
        RETURNING id INTO v_slack;

    -- Connections (twist_instances). owner_id must be set (trigger enforced).
    INSERT INTO twist_instance (id, twist_id, owner_id, name) VALUES
        (v_ti_work_gmail, v_gmail, v_user, 'Gmail'),
        (v_ti_work_slack, v_slack, v_user, 'Slack (work)'),
        (v_ti_personal,   v_gmail, v_user, 'Gmail (personal)');
    INSERT INTO twist_instance (id, twist_id, owner_id, name, team_id) VALUES
        (v_ti_team, v_slack, v_user, 'Team Slack', v_team);

    -- Connection rows linking each twist_instance to the owner's account contact.
    -- Work gmail + work slack both resolve to the work email (acme.com).
    INSERT INTO twist_instance_connection (twist_instance_id, user_id, provider, actor_id) VALUES
        (v_ti_work_gmail, v_user, 'gmail', v_user_c),
        (v_ti_work_slack, v_user, 'slack', v_user_c),
        (v_ti_personal,   v_user, 'gmail', v_c_pers);
    -- The team connection has no resolvable email contact (synthetic actor),
    -- so it should fall back to team_id.
    INSERT INTO twist_instance_connection (twist_instance_id, user_id, provider, actor_id) VALUES
        (v_ti_team, v_user, 'slack', gen_random_uuid()); -- synthetic actor: no contact row, so no resolvable email -> team fallback
END $$;

-- (1) Work Gmail -> org domain acme.com (acme.com is not a known freemail).
SELECT is(
    public.connection_org_key((SELECT id FROM twist_instance WHERE name='Gmail')),
    'domain:acme.com',
    'work gmail resolves to its non-freemail account domain');

-- (2) Work Slack -> SAME org key (same account email domain) -> transfer.
SELECT is(
    public.connection_org_key((SELECT id FROM twist_instance WHERE name='Slack (work)')),
    'domain:acme.com',
    'work slack resolves to the same org domain as work gmail');

-- (3) Personal Gmail (freemail) -> NULL (no merge across personal accounts).
SELECT is(
    public.connection_org_key((SELECT id FROM twist_instance WHERE name='Gmail (personal)')),
    NULL,
    'personal freemail connection has no org key');

-- (4) Team connection with no resolvable email -> team fallback.
SELECT is(
    public.connection_org_key((SELECT id FROM twist_instance WHERE name='Team Slack')),
    'team:' || (SELECT id FROM team WHERE name='Acme')::text,
    'team-owned connection without an account email falls back to team_id');

-- (5) NULL / unknown twist_instance -> NULL (null-safe).
SELECT is(
    public.connection_org_key(NULL),
    NULL,
    'null connection id resolves to null');

SELECT finish();
ROLLBACK;
