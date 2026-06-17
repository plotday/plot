-- Drop index "idx_priority_user_fyi" from table: "priority"
DROP INDEX "public"."idx_priority_user_fyi";

-- ============================================================================
-- Data backfill: move from one global FYI per user to one FYI per role.
-- The old per-user unique index is dropped above; the new per-role unique index
-- (idx_priority_role_fyi) is created at the END of this block, once the data
-- satisfies one-live-FYI-per-role.
-- ============================================================================

-- 1. Attach each user's existing global FYI (role_id IS NULL) to their OLDEST
--    live role, preserving the threads already filed there. Adopt the role's
--    colour and the fixed newspaper icon, and drop the legacy 'fyi' key (keys
--    are unique per root tree; the FYI is identified by is_fyi).
UPDATE public.priority p
SET role_id = oldest.role_id,
    color = oldest.color,
    icon = 'newspaper',
    key = NULL
FROM (
    SELECT r.user_id, r.id AS role_id, r.color,
           ROW_NUMBER() OVER (
               PARTITION BY r.user_id ORDER BY r.created_at ASC, r.id ASC
           ) AS rn
    FROM public.role r
    WHERE r.archived_at IS NULL
) oldest
WHERE p.is_fyi
  AND p.role_id IS NULL
  AND p.archived_at IS NULL
  AND oldest.user_id = p.user_id
  AND oldest.rn = 1;

-- 2. Create a muted FYI for every other live role that still lacks one. Child
--    of the user's root (mirrors upsert_role's path synthesis).
INSERT INTO public.priority
    (user_id, created_by, title, color, icon, is_fyi, role_id,
     early_notifications_enabled, path)
SELECT r.user_id, r.user_id, 'FYI', r.color, 'newspaper', TRUE, r.id, FALSE,
       public.generate_path(root.path)
FROM public.role r
JOIN LATERAL (
    SELECT path FROM public.priority
    WHERE user_id = r.user_id AND nlevel(path) = 1
    ORDER BY created_at ASC LIMIT 1
) root ON TRUE
WHERE r.archived_at IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM public.priority f
      WHERE f.role_id = r.id AND f.is_fyi AND f.archived_at IS NULL
  );

-- 3. Every live role now has exactly one live FYI — enforce it.
-- Create index "idx_priority_role_fyi" to table: "priority"
CREATE UNIQUE INDEX "idx_priority_role_fyi" ON "public"."priority" ("role_id") WHERE (is_fyi AND (archived_at IS NULL));

-- 4. Seed sentinel sidebar orders so each role's Inbox (1e15) then FYI (2e15)
--    default to the bottom two of the role; user focuses keep their
--    creation-time order, which sorts above. Then bump priority.updated_at so
--    clients re-pull the new order and the FYIs' new role_id (priority_setting
--    writes don't bump the parent on their own).
INSERT INTO public.priority_setting (user_id, priority_id, key, value)
SELECT p.user_id, p.id, 'order',
       to_jsonb((CASE WHEN p.is_fyi THEN 2e15 ELSE 1e15 END)::double precision)
FROM public.priority p
WHERE (p.is_inbox OR p.is_fyi) AND p.archived_at IS NULL
ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;

UPDATE public.priority
SET updated_at = now()
WHERE (is_inbox OR is_fyi) AND archived_at IS NULL;

-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    c_system_instance_id CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001'::uuid;
    v_root_priority_id uuid;
    v_fyi_priority_id uuid;
    v_default_role_id uuid;
    v_new_path ltree;
    -- Sentinel sidebar orders so the Inbox and FYI default to the last two
    -- focuses in their role (Inbox then FYI), while user focuses — which take a
    -- now()-epoch-ms order (~1.7e12) — sort above them. See user.priority's
    -- COALESCE(order, epoch_ms(created_at)) and priorities_list._byOrder.
    c_inbox_order CONSTANT double precision := 1e15;
    c_fyi_order CONSTANT double precision := 2e15;
    v_plot_team_group_id uuid;
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
    -- Every user gets a default "Personal" role (theme 0); the root priority
    -- becomes its Inbox. Create the role FIRST so the root can be inserted with
    -- role_id already set: the priority_role_or_fyi CHECK is evaluated at INSERT
    -- time, so the old "insert root, then UPDATE role_id" ordering would now
    -- fail. Mirrors the focus-roles backfill so new users match existing ones,
    -- guaranteeing every user has >=1 role and no role-less focus.
    -- default_role_user_id fills "order"; the root's colour is 0 and
    -- notifications NULL, so the Inbox trivially follows the role.
    INSERT INTO public.role (created_by, user_id, name, color)
        VALUES (p_user_id, p_user_id, 'Personal', 0)
    RETURNING
        id INTO v_default_role_id;
    -- Create the root priority as that role's Inbox. default_priority_user_id
    -- fills user_id from created_by, so the new row is fully owned by the user.
    v_new_path := generate_path (NULL);
    INSERT INTO public.priority (created_by, user_id, title, path, color, role_id, is_inbox)
        VALUES (p_user_id, p_user_id, 'Everything', v_new_path, 0, v_default_role_id, TRUE)
    RETURNING
        id INTO v_root_priority_id;
    -- The Personal role gets its own FYI focus (child of the root in the legacy
    -- ltree, role_id set, is_fyi TRUE), gathering low-signal mail. A normal,
    -- reorderable focus that defaults just below the role's Inbox; muted by
    -- default (early_notifications_enabled = FALSE, no notify_window). Newspaper
    -- icon. No key — idx_priority_key_per_root forbids duplicate keys per root,
    -- and the FYI is identified by is_fyi, not a key.
    INSERT INTO public.priority
        (created_by, user_id, title, path, color, icon, role_id, is_fyi,
         early_notifications_enabled)
    VALUES
        (p_user_id, p_user_id, 'FYI', generate_path(v_new_path), 0, 'newspaper',
         v_default_role_id, TRUE, FALSE)
    RETURNING
        id INTO v_fyi_priority_id;
    -- Seed sentinel sidebar orders so the Inbox then the FYI default to the
    -- bottom two of the role; user focuses (now()-epoch-ms order) sort above.
    INSERT INTO public.priority_setting (user_id, priority_id, key, value)
    VALUES
        (p_user_id, v_root_priority_id, 'order', to_jsonb(c_inbox_order)),
        (p_user_id, v_fyi_priority_id, 'order', to_jsonb(c_fyi_order))
    ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
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
        -- for peer-filing purposes. icon is the stable Plot logo URL (NOT
        -- 'twist:<id>', which resolves client-side via the per-user Plot
        -- twist_instance and would fall back to the generic twist icon when
        -- that instance is archived / not yet synced).
        -- contacts: the synthetic "Plot Team" sender (so the row header
        -- attributes the thread to Plot Team, same as the shared onboarding
        -- threads) PLUS the user's own contact (load-bearing for the user's
        -- own visibility — _otherContactIds excludes self, so only "Plot Team"
        -- shows). groups carries the Plot Team group so replies reach the team.
        -- ONBOARDING:BEGIN welcome-user
        INSERT INTO public.thread (created_by, icon, title, preview, key, topic, contacts, groups)
            VALUES (c_system_instance_id, 'https://plot.day/assets/plot-icon.svg',
                'Welcome to Plot!', 'We''re so glad something brought you here.', 'welcome-user', 'onboarding',
                ARRAY[c_system_instance_id] || (CASE WHEN v_user_contact_id IS NOT NULL THEN ARRAY[v_user_contact_id] ELSE ARRAY[]::uuid[] END),
                ARRAY[v_plot_team_group_id])
        RETURNING id INTO v_welcome_thread_id;
        INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
            VALUES (v_welcome_thread_id, p_user_id, v_root_priority_id)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;
        INSERT INTO public.thread_state (user_id, thread_id, importance, "order", "on")
            VALUES (p_user_id, v_welcome_thread_id, 100, 50, daterange('1970-01-01', NULL))
        ON CONFLICT (user_id, thread_id) DO NOTHING;
        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)
            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now() + interval '0 millisecond', 'We''re so glad something brought you here.
Maybe you''re trying to get traction on something new by bringing all the scattered pieces together.
You might be part of a team doing big things and want to overcome collaboration overhead.
Perhaps your life is full of many good things and you want to give them all your best.

Plot is built for making progress on what matters and getting more done with others.
Rather than chasing Inbox Zero, we believe in investing your time and attention based on your priorities.
Plot supports you working with others in the areas you choose while gathering everything else for the right time.

We''d love to hear what you''re working on and how Plot can help. Feel free to reply in this thread that includes the Plot team.', 'welcome')
        ON CONFLICT (thread_id, link_id, key) WHERE key IS NOT NULL DO NOTHING;
        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)
            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now() + interval '1 millisecond', 'Your account has been upgraded to the **Core plan** free for 30 days so you can try up to 5 connections and 2 twists. You can choose to keep the upgrade or go **Pro** at any time. Otherwise, after 30 days, you''ll automatically continue on the Free plan, which includes unlimited history and sharing. Any connections or twists over your new limit will be archived.', 'core-trial')
        ON CONFLICT (thread_id, link_id, key) WHERE key IS NOT NULL DO NOTHING;
-- ONBOARDING:END welcome-user
    END IF;
    -- Priority routing is learned from user moves (thread_priority.user_moved).
    -- New users start with no training examples; incoming threads land in the
    -- root priority (Inbox) until the user moves one into a focus they create.
    -- classify_thread_for_user then picks that focus up automatically for
    -- similar future threads.
    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
-- Modify "upsert_role" function
CREATE OR REPLACE FUNCTION "user"."upsert_role" ("user_id" uuid, "p_role" jsonb) RETURNS uuid LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
-- Resolve ambiguous bare identifiers (e.g. the priority_setting ON CONFLICT
-- target `user_id`, which collides with this function's `user_id` parameter) to
-- the table column, matching upsert_priority.
#variable_conflict use_column
DECLARE
    _role_id uuid := COALESCE((p_role ->> 'id')::uuid, uuidv7 ());
    _exists boolean;
    _archiving boolean := (p_role ? 'archived_at') AND (p_role ->> 'archived_at') IS NOT NULL;
    _root_path ltree;
    _inbox_id uuid;
    _fyi_id uuid;
    -- Sentinel sidebar orders: Inbox then FYI default to the bottom two of the
    -- role; user focuses (now()-epoch-ms order ~1.7e12) sort above them.
    c_inbox_order CONSTANT double precision := 1e15;
    c_fyi_order CONSTANT double precision := 2e15;
BEGIN
    -- SELECT EXISTS always yields a boolean row (never NULL on no-match), unlike
    -- SELECT TRUE INTO which assigns NULL when no row matches.
    SELECT
        EXISTS (
            SELECT 1 FROM public.role r
            WHERE r.id = _role_id
                AND r.user_id = upsert_role.user_id) INTO _exists;

    IF _archiving AND _exists THEN
        -- archive-only-when-empty: the role must have no live focuses other than
        -- its auto-managed Inbox and FYI.
        IF EXISTS (
            SELECT 1 FROM public.priority p
            WHERE p.role_id = _role_id
                AND NOT p.is_inbox
                AND NOT p.is_fyi
                AND p.archived_at IS NULL) THEN
            RAISE EXCEPTION 'role_not_empty' USING ERRCODE = 'check_violation';
        END IF;
        -- never archive the user's last non-archived role.
        IF (
            SELECT count(*) FROM public.role r
            WHERE r.user_id = upsert_role.user_id
                AND r.archived_at IS NULL) <= 1 THEN
            RAISE EXCEPTION 'role_last' USING ERRCODE = 'check_violation';
        END IF;
        UPDATE public.role
        SET archived_at = (p_role ->> 'archived_at')::timestamptz
        WHERE id = _role_id
            AND public.role.user_id = upsert_role.user_id;
        UPDATE public.priority
        SET archived_at = (p_role ->> 'archived_at')::timestamptz
        WHERE role_id = _role_id
            AND (is_inbox OR is_fyi);
        RETURN _role_id;
    END IF;

    INSERT INTO public.role (id, user_id, created_by, name, color, "order",
        early_notifications_enabled, notify_window, see_within)
        VALUES (_role_id, upsert_role.user_id, upsert_role.user_id,
            COALESCE(p_role ->> 'name', 'Role'),
            COALESCE((p_role ->> 'color')::integer, 0),
            (p_role ->> 'order')::double precision,
            (p_role ->> 'early_notifications_enabled')::boolean,
            CASE WHEN p_role ? 'notify_window' THEN p_role -> 'notify_window' END,
            CASE WHEN p_role ? 'see_within' THEN p_role -> 'see_within' END)
    ON CONFLICT (id)
        DO UPDATE SET
            name = COALESCE(p_role ->> 'name', role.name),
            color = COALESCE((p_role ->> 'color')::integer, role.color),
            "order" = COALESCE((p_role ->> 'order')::double precision, role."order"),
            early_notifications_enabled = CASE WHEN p_role ? 'early_notifications_enabled'
                THEN (p_role ->> 'early_notifications_enabled')::boolean
                ELSE role.early_notifications_enabled END,
            notify_window = CASE WHEN p_role ? 'notify_window'
                THEN p_role -> 'notify_window' ELSE role.notify_window END,
            see_within = CASE WHEN p_role ? 'see_within'
                THEN p_role -> 'see_within' ELSE role.see_within END;

    -- New role -> auto-create its Inbox and FYI focuses.
    IF NOT _exists THEN
        -- Synthesize a child-of-root path (mirrors upsert_priority's flat-client
        -- path synthesis). Both sit directly under the user's root.
        SELECT
            path INTO _root_path
        FROM public.priority
        WHERE public.priority.user_id = upsert_role.user_id
            AND nlevel(path) = 1
        ORDER BY created_at ASC
        LIMIT 1;
        INSERT INTO public.priority (id, user_id, created_by, title, color, is_inbox,
            role_id, early_notifications_enabled, notify_window, see_within, path)
        SELECT
            uuidv7 (), upsert_role.user_id, upsert_role.user_id, 'Inbox', r.color,
            TRUE, r.id, r.early_notifications_enabled, r.notify_window, r.see_within,
            CASE WHEN _root_path IS NULL THEN generate_path (NULL)
                ELSE _root_path || generate_path (NULL) END
        FROM public.role r
        WHERE r.id = _role_id
        RETURNING id INTO _inbox_id;
        -- The role's FYI focus: muted (no notifications), fixed newspaper icon,
        -- no key (idx_priority_key_per_root forbids duplicate keys per root; the
        -- FYI is identified by is_fyi).
        INSERT INTO public.priority (id, user_id, created_by, title, color, icon,
            is_fyi, role_id, early_notifications_enabled, path)
        SELECT
            uuidv7 (), upsert_role.user_id, upsert_role.user_id, 'FYI', r.color,
            'newspaper', TRUE, r.id, FALSE,
            CASE WHEN _root_path IS NULL THEN generate_path (NULL)
                ELSE _root_path || generate_path (NULL) END
        FROM public.role r
        WHERE r.id = _role_id
        RETURNING id INTO _fyi_id;
        -- Sentinel sidebar orders so the Inbox then the FYI default to the
        -- bottom two of the role; user focuses (now()-epoch-ms order) sort above.
        INSERT INTO public.priority_setting (user_id, priority_id, key, value)
        VALUES
            (upsert_role.user_id, _inbox_id, 'order', to_jsonb(c_inbox_order)),
            (upsert_role.user_id, _fyi_id, 'order', to_jsonb(c_fyi_order))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
    END IF;

    RETURN _role_id;
END;
$$;
