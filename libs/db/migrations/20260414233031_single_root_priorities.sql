-- Consolidate priorities to a single root and remove 'personal' flags.

-- 1. Remove 'personal' column from priority_user and drop related indexes
ALTER TABLE "public"."priority_user" DROP COLUMN IF EXISTS "personal";
DROP INDEX IF EXISTS idx_priority_user_personal_user;
DROP INDEX IF EXISTS idx_priority_user_personal_priority;

-- 2. Update user.priority view to remove 'personal' column
DROP VIEW IF EXISTS "user"."priority" CASCADE;
CREATE OR REPLACE VIEW "user"."priority"
AS
WITH user_root AS (
    SELECT DISTINCT ON (p.user_id)
        p.user_id,
        p.id AS root_id,
        p.path AS root_path
    FROM priority p
    WHERE nlevel(p.path) = 1
    ORDER BY p.user_id, p.created_at ASC
),
direct_settings AS (
    SELECT user_id, priority_id,
        MAX(CASE WHEN key = 'top_order' THEN (value #>> '{}')::double precision END) AS top_order,
        MAX(CASE WHEN key = 'order' THEN (value #>> '{}')::double precision END) AS "order",
        MAX(CASE WHEN key = 'title' THEN value #>> '{}' END) AS title,
        (MAX(CASE WHEN key = 'attention_window' THEN 1 END) IS NOT NULL) AS attention_window_set,
        (MAX(CASE WHEN key = 'see_within_requests' THEN 1 END) IS NOT NULL) AS see_within_requests_set,
        (MAX(CASE WHEN key = 'see_within_updates' THEN 1 END) IS NOT NULL) AS see_within_updates_set,
        MAX(updated_at) AS updated_at
    FROM priority_setting
    GROUP BY user_id, priority_id
),
inherited_settings AS (
    SELECT user_id, priority_id,
        MAX(CASE WHEN key = 'pomodoro' THEN (value #>> '{}')::integer END) AS pomodoro,
        MAX(CASE WHEN key = 'color' THEN (value #>> '{}')::integer END) AS color,
        MAX(CASE WHEN key = 'attention_window' THEN value::text END)::jsonb AS attention_window,
        MAX(CASE WHEN key = 'see_within_requests' THEN value::text END)::jsonb AS see_within_requests,
        MAX(CASE WHEN key = 'see_within_updates' THEN value::text END)::jsonb AS see_within_updates,
        MAX(CASE WHEN key = 'path' THEN value #>> '{}' END) AS path_value,
        MAX(CASE WHEN key = 'path' THEN text(source_path) END) AS path_source,
        MAX(updated_at) AS updated_at
    FROM priority_setting_inherited
    GROUP BY user_id, priority_id
)
SELECT
    p.user_id,
    p.id,
    p.created_at,
    GREATEST (
        direct.updated_at,
        p.updated_at,
        COALESCE(upu.updated_at, 'epoch'::timestamptz),
        inh.updated_at
    ) AS updated_at,
    p.archived_at,
    p.created_by,
    p.updated_by,
    p.id = ur.root_id AS root,
    COALESCE(direct.title, p.title) AS title,
    CASE
        WHEN inh.path_value IS NOT NULL THEN
            CASE WHEN inh.path_source IS NOT NULL
                AND p.path != inh.path_source::ltree
                AND subpath(p.path, nlevel(inh.path_source::ltree)) != '' THEN
                inh.path_value::ltree || subpath(p.path, nlevel(inh.path_source::ltree))
            ELSE
                inh.path_value::ltree
            END
        ELSE
            p.path
    END AS path,
    p.path AS global_path,
    direct.top_order,
    COALESCE(direct."order", extract(epoch FROM p.created_at) * 1000) AS "order",
    inh.pomodoro,
    inh.color,
    p.key,
    p.team_id,
    COALESCE(upu.unread, FALSE) AS unread,
    'member'::text AS role,
    inh.attention_window,
    inh.see_within_requests,
    inh.see_within_updates,
    COALESCE(direct.attention_window_set, FALSE) AS attention_window_set,
    COALESCE(direct.see_within_requests_set, FALSE) AS see_within_requests_set,
    COALESCE(direct.see_within_updates_set, FALSE) AS see_within_updates_set,
    p.inherit_members
FROM priority p
    LEFT JOIN user_root ur ON ur.user_id = p.user_id
    LEFT JOIN direct_settings direct ON direct.user_id = p.user_id AND direct.priority_id = p.id
    LEFT JOIN inherited_settings inh ON inh.user_id = p.user_id AND inh.priority_id = p.id
    LEFT JOIN "user".priority_unread upu ON upu.user_id = p.user_id AND upu.priority_id = p.id;

-- 3. Enforce single root in priority table
CREATE OR REPLACE FUNCTION public.validate_priority_root ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_root_path ltree;
BEGIN
    IF nlevel(NEW.path) = 1 THEN
        IF EXISTS (
            SELECT 1 FROM priority
            WHERE user_id = NEW.user_id AND nlevel(path) = 1 AND id != NEW.id
        ) THEN
            RAISE EXCEPTION 'User already has a root priority';
        END IF;
    ELSE
        SELECT path INTO v_root_path
        FROM priority
        WHERE user_id = NEW.user_id AND nlevel(path) = 1;

        IF v_root_path IS NULL THEN
            RAISE EXCEPTION 'User must have a root priority before adding sub-priorities';
        END IF;

        IF NOT v_root_path @> NEW.path THEN
            RAISE EXCEPTION 'Priority path % must be under root path %', NEW.path, v_root_path;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_priority_root_trigger ON public.priority;
CREATE TRIGGER validate_priority_root_trigger
    BEFORE INSERT OR UPDATE OF path, user_id ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION public.validate_priority_root ();

-- 4. Update topic table
ALTER TABLE "public"."topic" ADD COLUMN IF NOT EXISTS "auto_user_id" uuid REFERENCES public."user" ("id") ON DELETE CASCADE;
ALTER TABLE "public"."topic" ADD COLUMN IF NOT EXISTS "auto_team_admin_team_id" bigint REFERENCES team ON DELETE CASCADE;
ALTER TABLE "public"."topic" ADD COLUMN IF NOT EXISTS "auto_twist_admin_id" bigint REFERENCES twist_admin ON DELETE CASCADE;

DROP INDEX IF EXISTS idx_topic_auto_team;
CREATE UNIQUE INDEX idx_topic_auto_team ON "public"."topic" ("team_id")
WHERE
    auto_maintained = TRUE
    AND team_id IS NOT NULL
    AND auto_team_admin_team_id IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_topic_auto_team_admin ON "public"."topic" ("auto_team_admin_team_id")
WHERE
    auto_maintained = TRUE
    AND auto_team_admin_team_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_topic_auto_user ON "public"."topic" ("auto_user_id")
WHERE
    auto_maintained = TRUE
    AND auto_user_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_topic_auto_twist_admin ON "public"."topic" ("auto_twist_admin_id")
WHERE
    auto_maintained = TRUE
    AND auto_twist_admin_id IS NOT NULL;

DROP INDEX IF EXISTS idx_topic_auto_everyone;
CREATE UNIQUE INDEX idx_topic_auto_everyone ON "public"."topic" ("auto_maintained")
WHERE
    auto_maintained = TRUE
    AND team_id IS NULL
    AND auto_user_id IS NULL
    AND auto_twist_admin_id IS NULL;

-- 5. Backfill topics and rules for existing users
DO $$
DECLARE
    v_user RECORD;
    v_root RECORD;
    v_plot_app RECORD;
    v_twist_dev RECORD;
    v_topic_id uuid;
    v_team RECORD;
    v_ta RECORD;
BEGIN
    FOR v_user IN SELECT id FROM "user" LOOP
        -- Ensure root exists
        SELECT id, path INTO v_root
        FROM priority
        WHERE user_id = v_user.id AND nlevel(path) = 1
        ORDER BY created_at ASC
        LIMIT 1;

        IF v_root.id IS NOT NULL THEN
            -- Migrate @plot.app
            FOR v_plot_app IN SELECT id, path FROM priority WHERE user_id = v_user.id AND key = '@plot.app' LOOP
                UPDATE priority
                SET path = v_root.path || subpath(v_plot_app.path, nlevel(v_plot_app.path) - 1)
                WHERE id = v_plot_app.id;
            END LOOP;

            -- Migrate @plot.twist-dev
            FOR v_twist_dev IN SELECT id, path FROM priority WHERE user_id = v_user.id AND key = '@plot.twist-dev' LOOP
                UPDATE priority
                SET path = v_root.path || subpath(v_twist_dev.path, nlevel(v_twist_dev.path) - 1)
                WHERE id = v_twist_dev.id;
            END LOOP;

            -- Delete path overrides
            DELETE FROM priority_setting
            WHERE user_id = v_user.id AND key = 'path' AND priority_id IN (
                SELECT id FROM priority WHERE user_id = v_user.id AND key IN ('@plot.app', '@plot.twist-dev')
            );

            -- Ensure @plot.app and @plot.twist-dev exist if they didn't
            IF NOT EXISTS (SELECT 1 FROM priority WHERE user_id = v_user.id AND key = '@plot.app') THEN
                INSERT INTO priority (created_by, user_id, title, path, color, key, default_thread_icon)
                VALUES (v_user.id, v_user.id, 'Using Plot', v_root.path || generate_path(NULL), 7, '@plot.app', 'https://plot.day/assets/plot-icon.svg');
            END IF;
            IF NOT EXISTS (SELECT 1 FROM priority WHERE user_id = v_user.id AND key = '@plot.twist-dev') THEN
                INSERT INTO priority (created_by, user_id, title, path, color, key)
                VALUES (v_user.id, v_user.id, 'Twist Development', v_root.path || generate_path(NULL), 3, '@plot.twist-dev');
            END IF;

            -- Create User Topic
            INSERT INTO topic (name, type, auto_user_id, created_by, auto_maintained)
            VALUES ('Account Topic', 'private', v_user.id, v_user.id, TRUE)
            ON CONFLICT (auto_user_id) WHERE auto_maintained = TRUE DO NOTHING
            RETURNING id INTO v_topic_id;

            -- Create Priority Rule: Everyone -> Using Plot
            INSERT INTO priority_rule (user_id, priority_id, type, criteria, precedence)
            SELECT v_user.id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text]), 100
            FROM public.priority p
            CROSS JOIN public.topic t
            WHERE p.user_id = v_user.id AND p.key = '@plot.app'
              AND t.auto_maintained = TRUE AND t.team_id IS NULL AND t.name = 'Everyone'
            ON CONFLICT DO NOTHING;

            -- Create Priority Rule: User Topic -> Using Plot
            IF v_topic_id IS NOT NULL THEN
                INSERT INTO priority_rule (user_id, priority_id, type, criteria, precedence)
                SELECT v_user.id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[v_topic_id::text]), 100
                FROM public.priority p
                WHERE p.user_id = v_user.id AND p.key = '@plot.app'
                ON CONFLICT DO NOTHING;
            END IF;
        END IF;
    END LOOP;

    -- Backfill Team Admin topics
    FOR v_team IN SELECT id, name FROM team LOOP
        INSERT INTO topic (name, type, team_id, auto_team_admin_team_id, created_by, auto_maintained)
        VALUES (v_team.name || ' Admins', 'team', v_team.id, v_team.id, (SELECT user_id FROM team_user WHERE team_id = v_team.id LIMIT 1), TRUE)
        ON CONFLICT (auto_team_admin_team_id) WHERE auto_maintained = TRUE DO NOTHING
        RETURNING id INTO v_topic_id;

        IF v_topic_id IS NOT NULL THEN
            -- Rules for team admins
            FOR v_user IN SELECT user_id FROM team_user WHERE team_id = v_team.id AND role = 'admin' LOOP
                INSERT INTO priority_rule (user_id, priority_id, type, criteria, precedence)
                SELECT v_user.user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[v_topic_id::text]), 100
                FROM public.priority p
                WHERE p.user_id = v_user.user_id AND p.key = '@plot.app'
                ON CONFLICT DO NOTHING;
            END LOOP;
        END IF;
    END LOOP;

    -- Backfill Twist Admin topics
    FOR v_ta IN SELECT id, user_id FROM twist_admin WHERE user_id IS NOT NULL LOOP
        INSERT INTO topic (name, type, auto_twist_admin_id, created_by, auto_maintained)
        VALUES ('Twist Admins', 'private', v_ta.id, v_ta.user_id, TRUE)
        ON CONFLICT (auto_twist_admin_id) WHERE auto_maintained = TRUE DO NOTHING
        RETURNING id INTO v_topic_id;

        IF v_topic_id IS NOT NULL THEN
            -- Rule for twist admin
            INSERT INTO priority_rule (user_id, priority_id, type, criteria, precedence)
            SELECT v_ta.user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[v_topic_id::text]), 100
            FROM public.priority p
            WHERE p.user_id = v_ta.user_id AND p.key = '@plot.twist-dev'
            ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;
END $$;

-- 6. Consolidate twist sub-priorities
DO $$
DECLARE
    v_sub_priority RECORD;
BEGIN
    FOR v_sub_priority IN 
        SELECT p.id, p.user_id, parent.id as parent_id
        FROM priority p
        JOIN priority parent ON parent.path @> p.path AND parent.id != p.id
        WHERE parent.key = '@plot.twist-dev'
    LOOP
        UPDATE thread SET priority_id = v_sub_priority.parent_id WHERE priority_id = v_sub_priority.id;
        DELETE FROM priority WHERE id = v_sub_priority.id;
    END LOOP;
END $$;
