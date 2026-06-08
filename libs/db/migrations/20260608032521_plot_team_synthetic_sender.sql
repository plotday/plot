-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    c_system_instance_id CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001';
    c_twist_package_id CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_root_priority_id uuid;
    v_new_path ltree;
    v_plot_team_group_id uuid;
    v_plot_twist_id bigint;
    v_user_contact_id uuid;
    v_welcome_thread_id uuid;
BEGIN
    -- Already has a root priority?
    SELECT
        id INTO v_root_priority_id
    FROM
        public.priority
    WHERE
        user_id = p_user_id
        AND nlevel (path) = 1
    ORDER BY
        created_at ASC
    LIMIT 1;
    IF v_root_priority_id IS NOT NULL THEN
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;
    -- Create the root priority. default_priority_user_id fills user_id
    -- from created_by, so the new row is fully owned by the user.
    v_new_path := generate_path (NULL);
    INSERT INTO public.priority (created_by, user_id, title, path, color)
        VALUES (p_user_id, p_user_id, 'Everything', v_new_path, 0)
    RETURNING
        id INTO v_root_priority_id;
    -- Resolve the Plot Team group once — used for the welcome thread's
    -- groups array (so the user's first message reaches the Plot team).
    -- Prefer the full "Plot" team's auto-maintained group (everyone on the
    -- team, what we want in prod); fall back to the Plot publisher admin
    -- group for environments where the Plot team doesn't exist yet.
    SELECT
        COALESCE((
            SELECT
                g.id
            FROM public.group g
            JOIN public.team t ON t.id = g.team_id
            WHERE
                g.auto_maintained = TRUE
                AND g.auto_team_admin_team_id IS NULL
                AND t.name = 'Plot' LIMIT 1), (
        SELECT
            g.id
        FROM public.group g
        WHERE
            g.auto_maintained = TRUE
            AND g.auto_publisher_id = (
                SELECT
                    id
                FROM public.publisher
            WHERE
                name = 'Plot' LIMIT 1)
LIMIT 1)) INTO v_plot_team_group_id;
    -- No special hardcoded focuses are seeded. Onboarding threads (the
    -- per-user welcome below and the shared global onboarding set) land in
    -- the user's Inbox/root via classify_thread_for_user's root_fallback and
    -- a shared topic = 'onboarding'. The user organizes them however they
    -- like; moving one into a focus carries the rest along (topic match).
    -- Seed a per-user welcome thread authored by the shared system Plot
    -- twist_instance (same pattern as the global onboarding threads). The
    -- thread is visible only to the new user (via contacts) and the Plot
    -- Team (via groups). It pins to the top of the user's agenda with
    -- order = 50, ahead of the global 'welcome' thread (order = 100).
    --
    -- Skipped entirely when the Plot Team group hasn't been seeded yet —
    -- avoids noisy welcomes in ephemeral test databases that don't have
    -- the Plot publisher/team bootstrapped.
    IF v_plot_team_group_id IS NOT NULL THEN
        SELECT
            id INTO v_plot_twist_id
        FROM
            public.twist
        WHERE
            twist_package_id = c_twist_package_id
            AND environment = 'public'
        LIMIT 1;
        -- The API worker inserts the primary contact row a moment after
        -- this trigger runs, so user_contact may not exist yet. Seed it
        -- ourselves via upsert_user_contact (idempotent via ON CONFLICT
        -- (email) + ON CONFLICT (user_id, contact_id)) so the welcome
        -- thread's contacts array has the user's primary contact from
        -- the start.
        DECLARE v_user_email text;
        v_user_name text;
        v_user_avatar text;
        BEGIN
            SELECT
                email,
                name,
                avatar_url INTO v_user_email,
                v_user_name,
                v_user_avatar
            FROM
                public."user"
            WHERE
                id = p_user_id;
            IF v_user_email IS NOT NULL THEN
                PERFORM
                    public.upsert_user_contact (p_user_id, v_user_email, v_user_name, v_user_avatar);
            END IF;
        END;
        SELECT
            contact_id INTO v_user_contact_id
        FROM
            public.user_contact
        WHERE
            user_id = p_user_id
            AND "primary" = TRUE
            AND linked = TRUE
            AND archived_at IS NULL
        LIMIT 1;
        -- twist_id is intentionally NULL: welcome-user is a per-user thread
        -- and must not participate in cross-user (twist_id, key) dedup. The
        -- twist_instance_id in created_by is what makes this "twist-authored"
        -- for peer-filing purposes; icon preserves the visual attribution.
        -- contacts: the synthetic "Plot Team" sender (so the row header
        -- attributes the thread to Plot Team, same as the shared onboarding
        -- threads) PLUS the user's own contact (load-bearing for the user's
        -- own visibility — _otherContactIds excludes self, so only "Plot Team"
        -- shows). groups carries the Plot Team group so replies reach the team.
        INSERT INTO public.thread (created_by, icon, title, preview, key, topic, contacts, groups)
            VALUES (c_system_instance_id, CASE WHEN v_plot_twist_id IS NOT NULL THEN
                    'twist:' || v_plot_twist_id::text
                END, 'Welcome to Plot!', 'Glad something brought you here.', 'welcome-user', 'onboarding', ARRAY[c_system_instance_id] || (CASE WHEN v_user_contact_id IS NOT NULL THEN
                    ARRAY[v_user_contact_id]
                ELSE
                    ARRAY[]::uuid[]
                END), ARRAY[v_plot_team_group_id])
        RETURNING
            id INTO v_welcome_thread_id;
        -- file_thread_priority_peers short-circuits for twist-authored
        -- threads, so file the new user into their own Inbox (root) manually.
        INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
            VALUES (v_welcome_thread_id, p_user_id, v_root_priority_id)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey
            DO NOTHING;
        -- importance = 100 puts this thread at the top of Updates, above
        -- the global onboarding sequence seeded by file_onboarding_schedules
        -- (which starts at importance = 95 for the 'welcome' thread). It's an
        -- informational thread with no actionable todo, so no active flag.
        -- Plot team members are filed by file_thread_priority_for_group_members
        -- but do NOT receive a thread_state row — the welcome stays off their
        -- agendas.
        INSERT INTO public.thread_state (user_id, thread_id, importance, "order", "on")
            VALUES (p_user_id, v_welcome_thread_id, 100, 50, daterange('1970-01-01', NULL))
        ON CONFLICT (user_id, thread_id)
            DO NOTHING;
        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)
            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now(), 'Glad something brought you here. Maybe it''s a project you want to move forward, a team you want to work with more clearly, or a sense that more is possible when you direct your best energy into the work only you can do.

Plot is built for collaborating without getting buried — every conversation has a place, and the best of your day stays yours. Tell us what you''re trying to make progress on, where you''re stuck, or what''s not quite working yet. We read every reply.', 'welcome')
        ON CONFLICT (thread_id, link_id, key)
            WHERE key IS NOT NULL
            DO NOTHING;
        -- Announce the reverse trial on the same thread so the user sees
        -- plan status alongside their onboarding message. TrialReminder DO
        -- adds reminder-7day / reminder-2day / upgraded notes here later
        -- via addTrialNote() (keyed on note.key for idempotency).
        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)
            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now() + interval '1 millisecond', 'Your account has been upgraded to the **Core plan** free for 30 days so you can try up to 5 connections and 2 twists. You can choose to keep the upgrade or go **Pro** at any time. Otherwise, after 30 days, you''ll automatically continue on the Free plan, which includes unlimited history and sharing. Any connections or twists over your new limit will be archived.', 'core-trial')
        ON CONFLICT (thread_id, link_id, key)
            WHERE key IS NOT NULL
            DO NOTHING;
    END IF;
    -- Priority routing is learned from user moves (thread_priority.user_moved).
    -- New users start with no training examples; incoming threads land in the
    -- root priority (Inbox) until the user moves one into a focus they create.
    -- classify_thread_for_user then picks that focus up automatically for
    -- similar future threads.
    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
-- Modify "actor" view
CREATE OR REPLACE VIEW "user"."actor" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "type",
  "name",
  "email",
  "avatar_url",
  "self",
  "inviteable",
  "primary",
  "linked_user_id",
  "external_accounts"
) AS SELECT uc.user_id,
    a.id,
    a.created_at,
    GREATEST(uc.updated_at, a.updated_at) AS updated_at,
    GREATEST(uc.seq, a.seq) AS seq,
    COALESCE(a.archived_at, uc.archived_at) AS archived_at,
    a.type,
        CASE
            WHEN a.archived_at IS NULL AND uc.archived_at IS NULL THEN COALESCE(uc.name, a.name)
            ELSE NULL::text
        END AS name,
        CASE
            WHEN a.archived_at IS NULL AND uc.archived_at IS NULL THEN a.email
            ELSE NULL::text
        END AS email,
        CASE
            WHEN a.archived_at IS NULL AND uc.archived_at IS NULL THEN a.avatar_url
            ELSE NULL::text
        END AS avatar_url,
    (EXISTS ( SELECT 1
           FROM public.contact c_1
          WHERE c_1.id = a.id AND c_1.user_id = uc.user_id)) AS self,
    a.inviteable,
    true AS "primary",
    c.user_id AS linked_user_id,
    COALESCE(( SELECT json_agg(json_build_object('twist_instance_id', cea.twist_instance_id, 'provider', cea.provider, 'account_id', cea.account_id)) AS json_agg
           FROM public.contact_external_account cea
          WHERE cea.contact_id = a.id), '[]'::json) AS external_accounts
   FROM public.user_contact uc
     JOIN public.contact c ON c.id = uc.contact_id
     JOIN public.actor a ON a.id = c.id
  WHERE c.user_id IS NULL OR c."primary" = true
UNION ALL
 SELECT uc_primary.user_id,
    a.id,
    a.created_at,
    GREATEST(uc_primary.updated_at, a.updated_at) AS updated_at,
    GREATEST(uc_primary.seq, a.seq) AS seq,
    COALESCE(a.archived_at, uc_primary.archived_at) AS archived_at,
    a.type,
        CASE
            WHEN a.archived_at IS NULL AND uc_primary.archived_at IS NULL THEN a.name
            ELSE NULL::text
        END AS name,
        CASE
            WHEN a.archived_at IS NULL AND uc_primary.archived_at IS NULL THEN a.email
            ELSE NULL::text
        END AS email,
        CASE
            WHEN a.archived_at IS NULL AND uc_primary.archived_at IS NULL THEN a.avatar_url
            ELSE NULL::text
        END AS avatar_url,
    c.user_id = uc_primary.user_id AS self,
    a.inviteable,
    false AS "primary",
    c.user_id AS linked_user_id,
    COALESCE(( SELECT json_agg(json_build_object('twist_instance_id', cea.twist_instance_id, 'provider', cea.provider, 'account_id', cea.account_id)) AS json_agg
           FROM public.contact_external_account cea
          WHERE cea.contact_id = a.id), '[]'::json) AS external_accounts
   FROM public.contact c
     JOIN public.actor a ON a.id = c.id
     JOIN public.contact c_primary ON c_primary.user_id = c.user_id AND c_primary."primary" = true
     JOIN public.user_contact uc_primary ON uc_primary.contact_id = c_primary.id
  WHERE c."primary" = false
UNION ALL
 SELECT u.id AS user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.seq,
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    false AS self,
    a.inviteable,
    true AS "primary",
    NULL::uuid AS linked_user_id,
    '[]'::json AS external_accounts
   FROM public."user" u
     JOIN public.twist_instance pt ON pt.owner_id = u.id
     JOIN public.actor a ON a.id = pt.id
  WHERE a.id <> '0199b6f4-ae64-7718-0000-000000000001'::uuid
UNION ALL
 SELECT u.id AS user_id,
    a.id,
    a.created_at,
    a.updated_at,
    a.seq,
    a.archived_at,
    a.type,
    a.name,
    a.email,
    a.avatar_url,
    false AS self,
    false AS inviteable,
    true AS "primary",
    NULL::uuid AS linked_user_id,
    '[]'::json AS external_accounts
   FROM public."user" u
     CROSS JOIN public.actor a
  WHERE a.id = '0199b6f4-ae64-7718-0000-000000000001'::uuid;

-- ---------------------------------------------------------------------------
-- Data migration: name the synthetic sender "Plot Team" and attribute the
-- per-user welcome threads to it.
--
-- The system Plot twist instance (c_system_instance_id) is the author of the
-- shared onboarding / Plot Updates threads and the per-user welcome thread. It
-- is now surfaced to every user by the user.actor branch above, so renaming it
-- to "Plot Team" makes those threads' row header (and note authorship) read
-- "Plot Team" for all recipients. Replies already fan out to the Plot Team
-- group via thread.groups (see 20260604045030_onboarding_reply_scoping and the
-- activate_invited_user seed); this migration only changes the visible sender.
-- Idempotent.
-- ---------------------------------------------------------------------------

-- Rename the synthetic sender. The UPDATE bumps twist_instance.seq via the
-- existing trigger, so every client re-pulls the actor and picks up the new
-- name on its next /sync/actors.
UPDATE public.twist_instance
SET name = 'Plot Team'
WHERE id = '0199b6f4-ae64-7718-0000-000000000001'::uuid
  AND name <> 'Plot Team';

-- Backfill existing per-user welcome threads (key = 'welcome-user') so their
-- row header attributes to the synthetic sender, matching the forward seed in
-- activate_invited_user. The user's own contact stays in contacts (visibility);
-- _otherContactIds excludes self, so only "Plot Team" shows. The UPDATE bumps
-- thread.seq, so clients re-pull the thread with the new contacts.
UPDATE public.thread
SET contacts = array_append(COALESCE(contacts, ARRAY[]::uuid[]), '0199b6f4-ae64-7718-0000-000000000001'::uuid)
WHERE key = 'welcome-user'
  AND NOT ('0199b6f4-ae64-7718-0000-000000000001'::uuid = ANY (COALESCE(contacts, ARRAY[]::uuid[])));
