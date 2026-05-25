-- Drop "twist_instance_thread_schedule" view
DROP VIEW "public"."twist_instance_thread_schedule";
-- Drop "note_tags" view
DROP VIEW "user"."note_tags";
-- Drop "thread_tags" view
DROP VIEW "user"."thread_tags";
-- Drop "thread" view
DROP VIEW "user"."thread";
-- Modify "thread_state" table — add three booleans first so we can backfill,
-- then drop action_type. Splitting the combined ALTER avoids losing data.
ALTER TABLE "public"."thread_state"
    ADD COLUMN "active"  boolean NOT NULL DEFAULT false,
    ADD COLUMN "task"    boolean NOT NULL DEFAULT false,
    ADD COLUMN "to_read" boolean NOT NULL DEFAULT false;

-- Backfill from action_type:
--   'respond' / 'do' → active = TRUE (user previously cared enough to file → Doing)
--   'read'           → to_read = TRUE
--   'update'         → all FALSE (default)
UPDATE "public"."thread_state" SET "active"  = TRUE WHERE "action_type" IN ('respond', 'do');
UPDATE "public"."thread_state" SET "to_read" = TRUE WHERE "action_type" = 'read';

ALTER TABLE "public"."thread_state"
    DROP CONSTRAINT "thread_state_action_type_check",
    DROP COLUMN "action_type";
-- Create index "idx_thread_state_active" to table: "thread_state"
CREATE INDEX "idx_thread_state_active" ON "public"."thread_state" ("user_id", "order") WHERE active;
-- Create index "idx_thread_state_task" to table: "thread_state"
CREATE INDEX "idx_thread_state_task" ON "public"."thread_state" ("user_id") WHERE task;
-- Create index "idx_thread_state_to_read" to table: "thread_state"
CREATE INDEX "idx_thread_state_to_read" ON "public"."thread_state" ("user_id") WHERE to_read;
-- Modify "activate_invited_user" function
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    c_system_instance_id CONSTANT uuid := '0199b6f4-ae64-7718-0000-000000000001';
    c_twist_package_id CONSTANT uuid := '0199b6f4-ae64-7718-8a02-44716f30358f';
    v_root_priority_id uuid;
    v_using_plot_id uuid;
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
    -- Resolve the Plot Team group once — used for the Using Plot priority
    -- config and for the welcome thread's groups array. Prefer the full
    -- "Plot" team's auto-maintained group (everyone on the team, what we
    -- want in prod); fall back to the Plot publisher admin group for
    -- environments where the Plot team doesn't exist yet.
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
    -- Create Using Plot (@plot.app). Config pins new threads to the
    -- feedback topic, auto-shares them with the Plot team, and hides the
    -- agenda tab so the priority acts like a feedback channel. The
    -- `groupLabel` is what the UI renders on the locked chip, decoupled
    -- from whatever the underlying group happens to be named locally.
    INSERT INTO public.priority (created_by, user_id, title, path, color, key, default_thread_icon, config)
        VALUES (p_user_id, p_user_id, 'Using Plot', v_new_path || generate_path (NULL), 7, '@plot.app', 'https://plot.day/assets/plot-icon.svg', jsonb_build_object('topic', 'feedback', 'group', v_plot_team_group_id::text, 'groupLabel', 'Plot Team', 'view', 'activity'))
    RETURNING
        id INTO v_using_plot_id;
    -- Pin Using Plot to the bottom of the priorities list. The user.priority
    -- view falls back to `extract(epoch FROM created_at) * 1000` when no
    -- explicit order setting exists, which would put this priority above
    -- anything the user creates later (the activation row is the oldest).
    -- 1e15 sits well past any plausible epoch_ms value so every
    -- naturally-defaulted order sorts ahead of it.
    INSERT INTO public.priority_setting (user_id, priority_id, key, value)
        VALUES (p_user_id, v_using_plot_id, 'order', to_jsonb(1e15::double precision));
    -- Twist Development (@plot.twist-dev) is created lazily on first deploy
    -- via ensure_twist_dev_priority, so users who never develop twists don't
    -- carry an unused priority.
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
                END, 'Welcome to Plot!', 'Glad something brought you here.', 'welcome-user', 'priority:@plot.app:welcome-user', CASE WHEN v_user_contact_id IS NOT NULL THEN
                    ARRAY[v_user_contact_id]
                ELSE
                    ARRAY[]::uuid[]
                END, ARRAY[v_plot_team_group_id])
        RETURNING
            id INTO v_welcome_thread_id;
        -- file_thread_priority_peers short-circuits for twist-authored
        -- threads, so file the new user into their own Using Plot manually.
        INSERT INTO public.thread_priority (thread_id, user_id, priority_id)
            VALUES (v_welcome_thread_id, p_user_id, v_using_plot_id)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey
            DO NOTHING;
        -- importance = 100 puts this thread at the top of Updates, above
        -- the global onboarding sequence seeded by file_onboarding_schedules
        -- (which starts at importance = 95 for the 'welcome' thread).
        -- to_read = TRUE places it on the user's reading list (informational
        -- thread with no actionable todo). Plot team members are filed by
        -- file_thread_priority_for_group_members but do NOT receive a
        -- thread_state row — the welcome stays off their agendas.
        INSERT INTO public.thread_state (user_id, thread_id, to_read, importance, "order", "on")
            VALUES (p_user_id, v_welcome_thread_id, TRUE, 100, 50, daterange('1970-01-01', NULL))
        ON CONFLICT (user_id, thread_id)
            DO NOTHING;
        INSERT INTO public.note (author_id, created_by, thread_id, source_created_at, content, key)
            VALUES (c_system_instance_id, c_system_instance_id, v_welcome_thread_id, now(), 'Glad something brought you here. Maybe it''s a project you''re ready to move on, a team you want to work with more clearly, or a sense that more is possible when you direct your best energy into your most important work. Too much initiative gets absorbed by the overhead of modern work — tools built to move us faster that often leave us so busy and scattered that real progress slows to a crawl.

Plot is being built for a different way of working, one where you choose your focus and have what you need to make progress. Human initiative, creativity, and wisdom drive meaningful work forward, and technology should create the space for them to thrive.

We''d love to know what brought you to Plot and what you''re hoping to make progress on. Tell us what you''re trying to achieve, where you''re stuck, or what''s not quite working yet. We read every reply and shape Plot through what we''re learning together.', 'welcome')
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
    -- Onboarding routing is now learned from user moves (thread_priority.user_moved).
    -- New users start with no training examples; incoming threads land in the
    -- root priority until the user moves one into "Using Plot". classify_thread_for_user
    -- then picks that priority up automatically for similar future threads.
    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;
-- Modify "file_onboarding_schedules" function
CREATE OR REPLACE FUNCTION "public"."file_onboarding_schedules" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_thread_key text;
    v_date_offset integer;
    v_order integer;
    v_active boolean;
    v_to_read boolean;
    v_importance smallint;
BEGIN
    -- Skip if explicitly requested (e.g. during repair migrations for existing users)
    IF current_setting('plot.skip_onboarding_schedules', true) = 'true' THEN
        RETURN NEW;
    END IF;

    SELECT key INTO v_thread_key FROM public.thread WHERE id = NEW.thread_id;

    IF v_thread_key IN ('welcome', 'priorities', 'connections', 'getting-around', 'invest-your-time', 'twists', 'notifications', 'clean-up') THEN
        -- Onboarding partitions each thread into the unified feed:
        --   active=true  — threads that ask the user to take a concrete
        --                  action (matches the keys handled by
        --                  file_onboarding_todos). Lands in Doing.
        --   to_read=true — informational threads with no actionable todo.
        --                  Lands in the user's reading list.
        -- importance controls Updates ordering (higher = nearer the top).
        -- Values descend in the natural reading order; 'welcome-user'
        -- (importance 100, handled in activate_invited_user) sits above
        -- the global 'welcome' here.
        CASE v_thread_key
            WHEN 'welcome'           THEN v_date_offset := 0; v_order := 100; v_active := FALSE; v_to_read := TRUE;  v_importance := 95;
            WHEN 'priorities'        THEN v_date_offset := 0; v_order := 200; v_active := TRUE;  v_to_read := FALSE; v_importance := 90;
            WHEN 'connections'       THEN v_date_offset := 0; v_order := 300; v_active := TRUE;  v_to_read := FALSE; v_importance := 85;
            WHEN 'getting-around'    THEN v_date_offset := 0; v_order := 400; v_active := FALSE; v_to_read := TRUE;  v_importance := 80;
            WHEN 'invest-your-time'  THEN v_date_offset := 1; v_order := 50;  v_active := FALSE; v_to_read := TRUE;  v_importance := 75;
            WHEN 'twists'            THEN v_date_offset := 1; v_order := 100; v_active := TRUE;  v_to_read := FALSE; v_importance := 70;
            WHEN 'notifications'     THEN v_date_offset := 2; v_order := 100; v_active := TRUE;  v_to_read := FALSE; v_importance := 65;
            WHEN 'clean-up'          THEN v_date_offset := 3; v_order := 100; v_active := FALSE; v_to_read := TRUE;  v_importance := 60;
        END CASE;

        INSERT INTO public.thread_state (user_id, thread_id, active, to_read, importance, "order", "on")
        VALUES (
            NEW.user_id,
            NEW.thread_id,
            v_active,
            v_to_read,
            v_importance,
            v_order,
            CASE
                WHEN v_date_offset = 0 THEN daterange('1970-01-01', NULL)
                ELSE daterange((CURRENT_DATE + v_date_offset), NULL)
            END
        )
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END IF;

    RETURN NEW;
END;
$$;
-- Modify "file_thread_priority_peers" function
CREATE OR REPLACE FUNCTION "public"."file_thread_priority_peers" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_author_user_id uuid;
    v_old_contacts uuid[];
BEGIN
    IF NEW.contacts IS NULL OR cardinality(NEW.contacts) = 0 THEN
        RETURN NEW;
    END IF;

    -- Only auto-file peers for user-authored threads.
    IF NOT EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        RETURN NEW;
    END IF;
    v_author_user_id := NEW.created_by;

    IF TG_OP = 'UPDATE' THEN
        v_old_contacts := COALESCE(OLD.contacts, ARRAY[]::uuid[]);
    ELSE
        v_old_contacts := ARRAY[]::uuid[];
    END IF;

    -- Mark every peer pending classification. applied_default_channel_id
    -- is set by the consumer Worker once it knows the chosen priority.
    INSERT INTO thread_priority (thread_id, user_id, priority_id, classify_at)
    SELECT NEW.id, peer.user_id, NULL::uuid, now()
    FROM (
        SELECT DISTINCT uc.user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    ) peer
    ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

    -- thread_state for newly-added contacts only. Harmless while the
    -- parent thread_priority row is hidden — only surfaces in user.*
    -- views once the visibility filter admits the row. active/task/to_read
    -- and importance use the table defaults (FALSE, FALSE, FALSE, 50).
    INSERT INTO thread_state (user_id, thread_id)
    SELECT peer.user_id, NEW.id
    FROM (
        SELECT DISTINCT uc.user_id
        FROM unnest(NEW.contacts) AS arr(contact_id)
        JOIN public.user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
          AND arr.contact_id != ALL(v_old_contacts)
    ) peer
    ON CONFLICT (user_id, thread_id) DO NOTHING;

    RETURN NEW;
END;
$$;
-- Modify "share_thread" function
CREATE OR REPLACE FUNCTION "public"."share_thread" ("p_user_id" uuid, "p_thread_id" uuid, "p_add_contact_ids" uuid[] DEFAULT ARRAY[]::uuid[], "p_remove_contact_ids" uuid[] DEFAULT ARRAY[]::uuid[]) RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_current_contacts uuid[];
    v_new_contacts uuid[];
    v_needs_invitation uuid[];
    r RECORD;
BEGIN
    -- Validate caller has access to this thread
    IF NOT EXISTS (
        SELECT 1
        FROM thread_priority tp
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;

    -- Fetch current contacts
    SELECT contacts INTO v_current_contacts
    FROM thread
    WHERE id = p_thread_id;

    IF v_current_contacts IS NULL THEN
        v_current_contacts := ARRAY[]::uuid[];
    END IF;

    -- Compute new contacts: (current + add) - remove, deduplicated
    SELECT COALESCE(array_agg(DISTINCT cid), ARRAY[]::uuid[])
    INTO v_new_contacts
    FROM (
        SELECT unnest(v_current_contacts) AS cid
        UNION
        SELECT unnest(p_add_contact_ids)
    ) all_contacts
    WHERE cid != ALL(COALESCE(p_remove_contact_ids, ARRAY[]::uuid[]));

    -- Update thread.contacts — fires file_thread_priority_peers trigger
    UPDATE thread
    SET contacts = v_new_contacts
    WHERE id = p_thread_id;

    -- For each newly-added contact linked to a user, create thread_state
    -- so the thread appears as unread for them. The default booleans
    -- (active/task/to_read = FALSE) and importance (50) come from the
    -- table defaults.
    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(p_add_contact_ids) AS arr(contact_id)
        JOIN user_contact uc
          ON uc.contact_id = arr.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM p_user_id
    LOOP
        INSERT INTO thread_state (user_id, thread_id)
        VALUES (r.peer_user_id, p_thread_id)
        ON CONFLICT (user_id, thread_id) DO NOTHING;
    END LOOP;

    -- Collect contact_ids that need invitation emails (not linked to any user)
    SELECT COALESCE(array_agg(arr.contact_id), ARRAY[]::uuid[])
    INTO v_needs_invitation
    FROM unnest(p_add_contact_ids) AS arr(contact_id)
    WHERE NOT EXISTS (
        SELECT 1
        FROM user_contact uc
        WHERE uc.contact_id = arr.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
    );

    RETURN jsonb_build_object(
        'contacts', to_jsonb(v_new_contacts),
        'needs_invitation', to_jsonb(v_needs_invitation)
    );
END;
$$;
-- Create "upsert_thread_state" function
CREATE FUNCTION "user"."upsert_thread_state" ("user_id" uuid, "p_thread_id" uuid, "p_active" boolean DEFAULT false, "p_task" boolean DEFAULT false, "p_to_read" boolean DEFAULT false, "p_urgent" boolean DEFAULT false, "p_importance" smallint DEFAULT 50, "p_read_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_bumped_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_note_created_at" timestamptz DEFAULT NULL::timestamp with time zone, "p_order" double precision DEFAULT NULL::double precision, "p_on" daterange DEFAULT NULL::daterange, "p_at" tstzrange DEFAULT NULL::tstzrange, "p_set_active" boolean DEFAULT false, "p_set_task" boolean DEFAULT false, "p_set_to_read" boolean DEFAULT false, "p_set_urgent" boolean DEFAULT true, "p_set_importance" boolean DEFAULT true, "p_set_order" boolean DEFAULT false, "p_set_on" boolean DEFAULT false, "p_set_at" boolean DEFAULT false) RETURNS "public"."thread_state" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    v_priority_id uuid;
    v_row thread_state;
BEGIN
    SELECT
        tp.priority_id INTO v_priority_id
    FROM
        thread_priority tp
    WHERE
        tp.thread_id = p_thread_id
        AND tp.user_id = upsert_thread_state.user_id;
    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'Thread not found';
    END IF;

    INSERT INTO thread_state (user_id, thread_id, active, task, to_read, urgent, importance, read_at, bumped_at, "order", "on", "at")
        VALUES (upsert_thread_state.user_id, p_thread_id, COALESCE(p_active, FALSE), COALESCE(p_task, FALSE), COALESCE(p_to_read, FALSE), COALESCE(p_urgent, FALSE), COALESCE(p_importance, 50), p_read_at, p_bumped_at, p_order, p_on, p_at)
    ON CONFLICT (user_id, thread_id)
        DO UPDATE SET
            active = CASE WHEN p_set_active THEN EXCLUDED.active ELSE thread_state.active END,
            task = CASE WHEN p_set_task THEN EXCLUDED.task ELSE thread_state.task END,
            to_read = CASE WHEN p_set_to_read THEN EXCLUDED.to_read ELSE thread_state.to_read END,
            urgent = CASE WHEN p_set_urgent THEN EXCLUDED.urgent ELSE thread_state.urgent END,
            importance = CASE WHEN p_set_importance THEN EXCLUDED.importance ELSE thread_state.importance END,
            "order" = CASE WHEN p_set_order THEN EXCLUDED."order" ELSE thread_state."order" END,
            "on" = CASE WHEN p_set_on THEN EXCLUDED."on" ELSE thread_state."on" END,
            "at" = CASE WHEN p_set_at THEN EXCLUDED."at" ELSE thread_state."at" END,
            read_at = CASE
                -- Race condition: user read after the note was created → preserve their read
                -- Truncate to ms precision (see PRECISION BOUNDARY comment above)
                WHEN p_note_created_at IS NOT NULL
                    AND thread_state.read_at IS NOT NULL
                    AND thread_state.read_at >= date_trunc('milliseconds', p_note_created_at)
                THEN thread_state.read_at
                -- New activity or no timestamp context: use caller's value (NULL = unread)
                ELSE EXCLUDED.read_at
            END,
            bumped_at = CASE WHEN p_bumped_at IS NOT NULL THEN p_bumped_at ELSE thread_state.bumped_at END,
            updated_at = now()
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$;
-- Create "twist_instance_thread_schedule" view
CREATE VIEW "public"."twist_instance_thread_schedule" (
  "twist_instance_id",
  "thread_id",
  "user_id",
  "on",
  "at",
  "active",
  "task",
  "to_read",
  "read_at",
  "updated_at",
  "seq",
  "priority_id"
) AS SELECT a.created_by AS twist_instance_id,
    ts.thread_id,
    ts.user_id,
    ts."on",
    ts.at,
    ts.active,
    ts.task,
    ts.to_read,
    ts.read_at,
    ts.updated_at,
    ts.seq,
    tp.priority_id
   FROM public.twist_instance pt
     JOIN public.thread a ON a.created_by = pt.id
     JOIN public.thread_state ts ON ts.thread_id = a.id AND ts.user_id = pt.owner_id
     LEFT JOIN public.thread_priority tp ON tp.thread_id = a.id AND tp.user_id = pt.owner_id
  WHERE a.draft = false AND pt.archived_at IS NULL AND ts.updated_at > pt.created_at
  ORDER BY ts.updated_at;
-- Create "thread" view
CREATE VIEW "user"."thread" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "groups",
  "topic",
  "title",
  "preview",
  "icon",
  "merged_into_thread_id",
  "has_embedding",
  "auto_archived_by_thread_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "active",
  "task",
  "to_read",
  "urgent",
  "state_order",
  "state_on",
  "state_at",
  "activity_at",
  "agenda_at",
  "revoked"
) AS WITH link_agg AS (
         SELECT link.thread_id,
            max(link.source_created_at) AS source_created_at
           FROM public.link
          GROUP BY link.thread_id
        )
 SELECT tp.user_id,
    a.id,
    a.created_at,
    GREATEST(a.updated_at, COALESCE(a.last_note_created_at, '1970-01-01 00:00:00+00'::timestamp with time zone), tp.updated_at, COALESCE(ts.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone)) AS updated_at,
    GREATEST(a.seq, a.last_note_seq, tp.seq, COALESCE(ts.seq, '0'::xid8)) AS seq,
    a.updated_by,
    COALESCE(a.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
    COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id)) AS priority_id,
    upe.path AS priority_path,
    a.draft,
    a.contacts,
    a.groups,
    a.topic,
    a.title,
    a.preview,
    a.icon,
    a.merged_into_thread_id,
    a.embedding IS NOT NULL AS has_embedding,
    tp.auto_archived_by_thread_id,
    a.last_note_created_at,
    a.last_note_source_created_at,
    ts.bumped_at,
    COALESCE(ts.read_at IS NULL AND ts.user_id IS NOT NULL, false) AS unread,
    COALESCE(ts.importance, 0::smallint) AS importance,
    COALESCE(ts.active, false) AS active,
    COALESCE(ts.task, false) AS task,
    COALESCE(ts.to_read, false) AS to_read,
    ts.urgent,
    ts."order" AS state_order,
    ts."on" AS state_on,
    ts.at AS state_at,
    COALESCE(GREATEST(a.last_note_source_created_at, la.source_created_at, ts.bumped_at, ( SELECT
                CASE
                    WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone) <= now() THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamp with time zone)
                    ELSE NULL::timestamp with time zone
                END AS "case"
           FROM public.schedule s_feed
          WHERE s_feed.thread_id = a.id AND s_feed.occurrence IS NULL AND s_feed.archived_at IS NULL
         LIMIT 1)), a.created_at) AS activity_at,
    ( SELECT tstzrange(bounds.lo, GREATEST(bounds.lo, bounds.hi), '[]'::text) AS tstzrange
           FROM ( SELECT COALESCE(LEAST(( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                          WHERE s_lo.thread_id = a.id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1), COALESCE(lower(ts.at), lower(ts."on")::timestamp with time zone), ( SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone) AS "coalesce"
                           FROM public.schedule s_lo
                             JOIN public.link l_lo ON l_lo.id = s_lo.link_id
                          WHERE l_lo.thread_id = a.id AND s_lo.archived_at IS NULL
                          ORDER BY (COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamp with time zone))
                         LIMIT 1)), a.created_at) AS lo,
                    COALESCE(
                        CASE
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                              WHERE s_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_rec
                                 JOIN public.link l_rec ON l_rec.id = s_rec.link_id
                              WHERE l_rec.thread_id = a.id AND s_rec.archived_at IS NULL AND s_rec.recurrence_rule IS NOT NULL)) THEN 'infinity'::timestamp with time zone
                            WHEN (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                              WHERE s_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) OR (EXISTS ( SELECT 1
                               FROM public.schedule s_ub
                                 JOIN public.link l_ub ON l_ub.id = s_ub.link_id
                              WHERE l_ub.thread_id = a.id AND s_ub.archived_at IS NULL AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL) AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamp with time zone) IS NULL)) THEN 'infinity'::timestamp with time zone
                            ELSE GREATEST(( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                              WHERE s_hi.thread_id = a.id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1), COALESCE(upper(ts.at), upper(ts."on")::timestamp with time zone), ( SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone) AS "coalesce"
                               FROM public.schedule s_hi
                                 JOIN public.link l_hi ON l_hi.id = s_hi.link_id
                              WHERE l_hi.thread_id = a.id AND s_hi.archived_at IS NULL
                              ORDER BY (COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamp with time zone)) DESC NULLS LAST
                             LIMIT 1))
                        END, a.created_at) AS hi) bounds) AS agenda_at,
    false AS revoked
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
     JOIN public.priority p ON p.id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
     LEFT JOIN public.thread_state ts ON ts.user_id = tp.user_id AND ts.thread_id = a.id
     LEFT JOIN link_agg la ON la.thread_id = a.id
  WHERE tp.revoked_at IS NULL AND (a.draft = false OR a.created_by = tp.user_id) AND (a.contacts && "user".user_contact_ids(tp.user_id) OR a.groups && "user".user_group_ids(tp.user_id)) AND (tp.priority_id IS NOT NULL OR tp.classify_at < (now() - public.classify_visibility_window())) AND (p.team_id IS NULL OR (EXISTS ( SELECT 1
           FROM public.team_user tu2
          WHERE tu2.team_id = p.team_id AND tu2.user_id = tp.user_id AND tu2.archived_at IS NULL)));
-- Drop "thread_redacted" view
DROP VIEW "user"."thread_redacted";
-- Create "thread_redacted" view
CREATE VIEW "user"."thread_redacted" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "updated_by",
  "archived_at",
  "priority_id",
  "priority_path",
  "draft",
  "contacts",
  "groups",
  "topic",
  "title",
  "preview",
  "icon",
  "merged_into_thread_id",
  "has_embedding",
  "auto_archived_by_thread_id",
  "last_note_created_at",
  "last_note_source_created_at",
  "bumped_at",
  "unread",
  "importance",
  "active",
  "task",
  "to_read",
  "urgent",
  "state_order",
  "state_on",
  "state_at",
  "activity_at",
  "agenda_at",
  "revoked"
) AS SELECT tp.user_id,
    a.id,
    a.created_at,
    tp.revoked_at AS updated_at,
    tp.seq,
    a.updated_by,
    tp.revoked_at AS archived_at,
    COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id)) AS priority_id,
    upe.path AS priority_path,
    a.draft,
    ARRAY[]::uuid[] AS contacts,
    ARRAY[]::uuid[] AS groups,
    NULL::text AS topic,
    NULL::text AS title,
    NULL::text AS preview,
    NULL::text AS icon,
    NULL::uuid AS merged_into_thread_id,
    false AS has_embedding,
    NULL::uuid AS auto_archived_by_thread_id,
    NULL::timestamp with time zone AS last_note_created_at,
    NULL::timestamp with time zone AS last_note_source_created_at,
    NULL::timestamp with time zone AS bumped_at,
    false AS unread,
    0::smallint AS importance,
    false AS active,
    false AS task,
    false AS to_read,
    NULL::boolean AS urgent,
    NULL::double precision AS state_order,
    NULL::daterange AS state_on,
    NULL::tstzrange AS state_at,
    a.created_at AS activity_at,
    tstzrange(a.created_at, a.created_at, '[]'::text) AS agenda_at,
    true AS revoked
   FROM public.thread a
     JOIN public.thread_priority tp ON tp.thread_id = a.id
     LEFT JOIN "user".priority_expanded upe ON upe.user_id = tp.user_id AND upe.priority_id = COALESCE(tp.priority_id, "user".root_priority_id(tp.user_id))
  WHERE tp.revoked_at IS NOT NULL;
-- Create "note_tags" view
CREATE VIEW "user"."note_tags" (
  "user_id",
  "id",
  "updated_at",
  "seq",
  "archived_at",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    n.id,
    nt.updated_at,
    nt.seq,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
   FROM "user".thread ua
     JOIN public.note n ON n.thread_id = ua.id
     JOIN LATERAL ( SELECT jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT nt_1.tag_id,
                    jsonb_agg(nt_1.actor_id ORDER BY nt_1.actor_id) FILTER (WHERE nt_1.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(nt_1.archived_at, nt_1.updated_at)) AS updated_at,
                    max(nt_1.seq) AS seq
                   FROM public.note_tag nt_1
                  WHERE nt_1.note_id = n.id
                  GROUP BY nt_1.tag_id) sq
         HAVING count(*) > 0) nt ON true
  WHERE (n.draft = false OR n.created_by = ua.user_id) AND (n.access_contacts IS NULL OR n.created_by = ua.user_id OR n.access_contacts && "user".user_contact_ids(ua.user_id));
-- Create "thread_tags" view
CREATE VIEW "user"."thread_tags" (
  "user_id",
  "id",
  "archived_at",
  "occurrence",
  "updated_at",
  "seq",
  "priority_id",
  "priority_path",
  "tags"
) AS SELECT ua.user_id,
    ua.id,
    ua.archived_at,
    tt.occurrence,
    tt.updated_at,
    tt.seq,
    ua.priority_id,
    ua.priority_path,
    tt.tags
   FROM "user".thread ua
     JOIN LATERAL ( SELECT sq.occurrence,
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            max(sq.updated_at) AS updated_at,
            max(sq.seq) AS seq
           FROM ( SELECT at.occurrence,
                    at.tag_id,
                    jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
                    max(COALESCE(at.archived_at, at.updated_at)) AS updated_at,
                    max(at.seq) AS seq
                   FROM public.thread_tag at
                  WHERE at.thread_id = ua.id
                  GROUP BY at.occurrence, at.tag_id) sq
          GROUP BY sq.occurrence) tt ON true;
-- Drop "upsert_thread_state" function
DROP FUNCTION "user"."upsert_thread_state" (uuid, uuid, text, boolean, smallint, timestamptz, timestamptz, timestamptz, double precision, daterange, tstzrange, boolean, boolean, boolean, boolean, boolean, boolean);

-- Bump thread.updated_at for every thread with a thread_state row so the
-- new user.thread columns (active / task / to_read) reach clients via
-- the seq cursor. See libs/db/AGENTS.md "Bump Parent seq on Child-Table
-- Changes" — the parent here is thread, the child is thread_state.
UPDATE "public"."thread" SET "updated_at" = now()
WHERE "id" IN (SELECT DISTINCT "thread_id" FROM "public"."thread_state");
