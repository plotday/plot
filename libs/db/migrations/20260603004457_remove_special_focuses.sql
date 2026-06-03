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
        INSERT INTO public.thread (created_by, icon, title, preview, key, topic, contacts, groups)
            VALUES (c_system_instance_id, CASE WHEN v_plot_twist_id IS NOT NULL THEN
                    'twist:' || v_plot_twist_id::text
                END, 'Welcome to Plot!', 'Glad something brought you here.', 'welcome-user', 'onboarding', CASE WHEN v_user_contact_id IS NOT NULL THEN
                    ARRAY[v_user_contact_id]
                ELSE
                    ARRAY[]::uuid[]
                END, ARRAY[v_plot_team_group_id])
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
-- Modify "mark_reclassify_candidates" function
CREATE OR REPLACE FUNCTION "public"."mark_reclassify_candidates" ("p_user_id" uuid, "p_anchor_thread_id" uuid, "p_max_candidates" integer DEFAULT 500) RETURNS TABLE ("user_id" uuid, "thread_id" uuid) LANGUAGE plpgsql AS $$
DECLARE
    v_topic text;
    v_embedding halfvec;
    v_contacts uuid[];
    v_groups uuid[];
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('mark_reclassify_candidates:' || p_user_id::text, 0)
    );

    SELECT t.topic, t.embedding, t.contacts, t.groups
    INTO v_topic, v_embedding, v_contacts, v_groups
    FROM public.thread t
    WHERE t.id = p_anchor_thread_id;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- No-op when the user has no training examples yet — same rationale
    -- as the old function (classifier would yank rows into root).
    IF NOT EXISTS (
        SELECT 1 FROM public.thread_priority tp
        WHERE tp.user_id = p_user_id AND tp.user_moved = TRUE
    ) THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH candidates AS MATERIALIZED (
        SELECT t.id
        FROM public.thread t
        JOIN public.thread_priority tp
          ON tp.thread_id = t.id
         AND tp.user_id = p_user_id
         AND tp.user_moved = FALSE
         AND tp.priority_id IS NOT NULL
        WHERE v_topic IS NOT NULL
          AND t.topic = v_topic
          AND t.archived_at IS NULL
          AND t.draft = FALSE

        UNION

        SELECT id FROM (
            SELECT t.id, (t.embedding <=> v_embedding) AS dist
            FROM public.thread t
            JOIN public.thread_priority tp
              ON tp.thread_id = t.id
             AND tp.user_id = p_user_id
             AND tp.user_moved = FALSE
             AND tp.priority_id IS NOT NULL
            WHERE v_embedding IS NOT NULL
              AND t.embedding IS NOT NULL
              AND (1 - (t.embedding <=> v_embedding)) >= 0.5
              AND t.archived_at IS NULL
              AND t.draft = FALSE
              -- Onboarding threads stay pinned to the Inbox: they're only
              -- ever dragged along the topic branch above (when the moved
              -- anchor is itself an 'onboarding' thread), never pulled out
              -- by similarity to some unrelated thread the user moved.
              AND t.topic IS DISTINCT FROM 'onboarding'
            ORDER BY t.embedding <=> v_embedding ASC
            LIMIT p_max_candidates
        ) semantic

        UNION

        SELECT t.id
        FROM public.thread t
        JOIN public.thread_priority tp
          ON tp.thread_id = t.id
         AND tp.user_id = p_user_id
         AND tp.user_moved = FALSE
         AND tp.priority_id IS NOT NULL
        WHERE t.archived_at IS NULL
          AND t.draft = FALSE
          -- Onboarding threads only move via the topic branch (see above).
          AND t.topic IS DISTINCT FROM 'onboarding'
          AND (
              (cardinality(v_contacts) > 0 AND t.contacts && v_contacts)
              OR (cardinality(v_groups) > 0 AND t.groups && v_groups)
          )
    )
    UPDATE public.thread_priority tp
    SET classify_at = now(),
        updated_at = now()
    FROM candidates c
    WHERE tp.thread_id = c.id
      AND tp.user_id = p_user_id
      AND tp.user_moved = FALSE
      AND tp.priority_id IS NOT NULL
      AND c.id IS DISTINCT FROM p_anchor_thread_id
    RETURNING tp.user_id, tp.thread_id;
END;
$$;
-- Modify "team_user_ensure_team_priority" function
CREATE OR REPLACE FUNCTION "public"."team_user_ensure_team_priority" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_root_path ltree;
    v_team_name text;
    v_existing_count int;
BEGIN
    -- Only fire when membership becomes active.
    IF NEW.archived_at IS NOT NULL THEN
        RETURN NULL;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.archived_at IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT path INTO v_root_path
    FROM public.priority
    WHERE user_id = NEW.user_id AND nlevel(path) = 1
    LIMIT 1;
    IF v_root_path IS NULL THEN
        RAISE EXCEPTION 'user % has no root priority', NEW.user_id;
    END IF;

    SELECT name INTO v_team_name FROM public.team WHERE id = NEW.team_id;

    -- If the user already has any non-archived top-level priority with
    -- this team_id, skip (rejoin case where the priority survived).
    SELECT count(*) INTO v_existing_count
    FROM public.priority
    WHERE user_id = NEW.user_id
      AND team_id = NEW.team_id
      AND nlevel(path) = 2
      AND archived_at IS NULL;
    IF v_existing_count > 0 THEN
        RETURN NULL;
    END IF;

    -- generate_path(NULL) produces a random 12-char alphanumeric label,
    -- matching the convention used in activate_invited_user.
    INSERT INTO public.priority (created_by, user_id, title, path, team_id)
    VALUES (
        NEW.user_id,
        NEW.user_id,
        v_team_name,
        v_root_path || generate_path(NULL),
        NEW.team_id
    );

    RETURN NULL;
END;
$$;
-- Drop "group" view
DROP VIEW "user"."group";
-- Create "group" view
CREATE VIEW "user"."group" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "name",
  "type",
  "key",
  "join_policy",
  "team_id",
  "auto_maintained",
  "is_admin",
  "is_member",
  "can_post",
  "member_contact_ids"
) AS SELECT u.id AS user_id,
    g.id,
    g.created_at,
    g.updated_at,
    g.seq,
    g.archived_at,
    g.name,
    g.type,
    g.key,
    g.join_policy,
    g.team_id,
    g.auto_maintained,
    (EXISTS ( SELECT 1
           FROM public.group_admin ga
          WHERE ga.group_id = g.id AND ga.user_id = u.id)) AS is_admin,
    (EXISTS ( SELECT 1
           FROM public.group_member gm
             JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE gm.group_id = g.id AND uc.user_id = u.id)) AS is_member,
    (EXISTS ( SELECT 1
           FROM public.group_admin ga
          WHERE ga.group_id = g.id AND ga.user_id = u.id)) OR g.type <> 'announce'::public.group_type AND (EXISTS ( SELECT 1
           FROM public.group_member gm
             JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE gm.group_id = g.id AND uc.user_id = u.id)) AS can_post,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM public.group_admin ga
              WHERE ga.group_id = g.id AND ga.user_id = u.id)) THEN ( SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[]) AS "coalesce"
               FROM public.group_member gm2
              WHERE gm2.group_id = g.id)
            WHEN (g.type = ANY (ARRAY['private'::public.group_type, 'team'::public.group_type])) AND (EXISTS ( SELECT 1
               FROM public.group_member gm
                 JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
              WHERE gm.group_id = g.id AND uc.user_id = u.id)) THEN ( SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[]) AS "coalesce"
               FROM public.group_member gm2
              WHERE gm2.group_id = g.id)
            ELSE ARRAY[]::uuid[]
        END AS member_contact_ids
   FROM public."user" u
     CROSS JOIN public."group" g
  WHERE g.archived_at IS NULL AND ((g.type = ANY (ARRAY['public'::public.group_type, 'announce'::public.group_type])) OR g.key = '@plot.team'::text OR g.type = 'team'::public.group_type AND (EXISTS ( SELECT 1
           FROM public.team_user tu
          WHERE tu.team_id = g.team_id AND tu.user_id = u.id)) OR g.type = 'private'::public.group_type AND ((EXISTS ( SELECT 1
           FROM public.group_admin ga
          WHERE ga.group_id = g.id AND ga.user_id = u.id)) OR (EXISTS ( SELECT 1
           FROM public.group_member gm
             JOIN public.user_contact uc ON uc.contact_id = gm.contact_id AND uc.linked = true AND uc.archived_at IS NULL
          WHERE gm.group_id = g.id AND uc.user_id = u.id))));
-- Drop "ensure_twist_dev_priority" function
DROP FUNCTION "public"."ensure_twist_dev_priority";

-- ============================================================================
-- Data migration: retire the hardcoded "Using Plot" (@plot.app) and
-- "Twist Development" (@plot.twist-dev) focuses, and align existing onboarding
-- threads with the new Inbox model.
-- ============================================================================
DO $migration$
DECLARE
    c_twist_package_id CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_plot_twist_id bigint;
BEGIN
    -- 1. Archive the two special per-user focuses. archived_at (never DELETE)
    --    keeps the change sync-safe; effective_priority_id then projects their
    --    threads into each user's Inbox (root) on the client.
    UPDATE public.priority
    SET archived_at = now()
    WHERE key IN ('@plot.app', '@plot.twist-dev')
      AND archived_at IS NULL;

    -- 2. Tag existing onboarding threads with the shared 'onboarding' topic so
    --    the classifier guards (priority-match find-matching-threads +
    --    mark_reclassify_candidates) keep them pinned to the Inbox, and moving
    --    one onboarding thread carries the rest along (topic_shortcircuit).
    --    Per-user welcome-user threads (twist_id IS NULL):
    UPDATE public.thread
    SET topic = 'onboarding'
    WHERE key = 'welcome-user'
      AND twist_id IS NULL
      AND topic IS DISTINCT FROM 'onboarding';

    --    Shared global onboarding set (scoped by the system Plot twist_id):
    SELECT id INTO v_plot_twist_id
    FROM public.twist
    WHERE twist_package_id = c_twist_package_id
      AND environment = 'public'
    LIMIT 1;

    IF v_plot_twist_id IS NOT NULL THEN
        UPDATE public.thread
        SET topic = 'onboarding'
        WHERE twist_id = v_plot_twist_id
          AND key IN ('welcome', 'priorities', 'connections', 'getting-around', 'twists', 'notifications', 'clean-up')
          AND topic IS DISTINCT FROM 'onboarding';
    END IF;

    -- 3. Bump every group's updated_at/seq so clients re-pull and pick up the
    --    new user.group.key column (per libs/db/AGENTS.md "bump on view-column add").
    UPDATE public."group" SET updated_at = now();
END $migration$;
