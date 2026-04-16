-- Drops twist_admin and folds its ownership + package identity directly into
-- the twist and publisher tables. Access control moves to per-publisher topics
-- (auto_publisher_id) and per-user personal-twist topics
-- (auto_personal_twist_user_id). Consolidates duplicate Plot publishers,
-- backfills topic members/admins (including kris as admin of every publisher
-- topic), and mints a publisher token so CI can deploy.

-- ---------------------------------------------------------------------------
-- Phase 0: Drop dependent views/functions so we can modify twist/topic.
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS "user"."twist" CASCADE;
DROP VIEW IF EXISTS "public"."priority_child_twist" CASCADE;
DROP FUNCTION IF EXISTS "public"."get_accessible_twists"(uuid);
DROP FUNCTION IF EXISTS "public"."is_accessible_twist"(bigint, uuid);

-- Drop the legacy twist_admin_id index before we drop the column.
DROP INDEX IF EXISTS "public"."twist_admin_environment_unique";
DROP INDEX IF EXISTS "public"."idx_twist_admin_id";

-- ---------------------------------------------------------------------------
-- Phase 1: Consolidate duplicate publishers by name.
-- In prod there are 4 "Plot" publisher rows (ids 1, 2, 3, 4). Canonicalize
-- each name to its lowest id so the unique index on lower(name) added below
-- has a single survivor per name, repoint every twist_admin to that id, then
-- delete the higher-id siblings.
-- ---------------------------------------------------------------------------
WITH canonical AS (
    SELECT DISTINCT ON (lower(name))
        lower(name) AS lname,
        id AS canonical_id
    FROM publisher
    ORDER BY lower(name), id ASC
)
UPDATE twist_admin ta
SET publisher_id = c.canonical_id
FROM publisher p
JOIN canonical c ON c.lname = lower(p.name)
WHERE ta.publisher_id = p.id
  AND p.id <> c.canonical_id;

DELETE FROM publisher p
WHERE EXISTS (
    SELECT 1 FROM publisher p2
    WHERE lower(p2.name) = lower(p.name) AND p2.id < p.id
);

-- ---------------------------------------------------------------------------
-- Phase 2: Add new columns (nullable first so existing rows are accepted).
-- ---------------------------------------------------------------------------
ALTER TABLE "public"."publisher"
    ADD COLUMN "created_by" uuid
        REFERENCES "public"."user" ("id") ON DELETE RESTRICT;

ALTER TABLE "public"."twist"
    ADD COLUMN "twist_package_id" uuid,
    ADD COLUMN "publisher_id" bigint
        REFERENCES "public"."publisher" ("id") ON DELETE CASCADE,
    ADD COLUMN "user_id" uuid
        REFERENCES "public"."user" ("id") ON DELETE CASCADE,
    ADD COLUMN "auto_approve" boolean NOT NULL DEFAULT FALSE;

ALTER TABLE "public"."topic"
    ADD COLUMN "auto_publisher_id" bigint
        REFERENCES "public"."publisher" ("id") ON DELETE CASCADE,
    ADD COLUMN "auto_personal_twist_user_id" uuid
        REFERENCES "public"."user" ("id") ON DELETE CASCADE;

-- ---------------------------------------------------------------------------
-- Phase 3: Backfill publisher.created_by.
--   For publishers whose twist_admins have any user_id rows, use the earliest
--   user_id. Otherwise fall back to kris@plot.day (sole deploy-token holder).
-- ---------------------------------------------------------------------------
UPDATE publisher p
SET created_by = (
    SELECT ta.user_id
    FROM twist_admin ta
    WHERE ta.publisher_id = p.id AND ta.user_id IS NOT NULL
    ORDER BY ta.created_at ASC
    LIMIT 1
)
WHERE created_by IS NULL
  AND EXISTS (
      SELECT 1 FROM twist_admin ta
      WHERE ta.publisher_id = p.id AND ta.user_id IS NOT NULL
  );

UPDATE publisher
SET created_by = (SELECT id FROM "public"."user" WHERE email = 'kris@plot.day' LIMIT 1)
WHERE created_by IS NULL;

ALTER TABLE "public"."publisher"
    ALTER COLUMN "created_by" SET NOT NULL;

-- ---------------------------------------------------------------------------
-- Phase 4: Backfill twist columns from twist_admin.
-- ---------------------------------------------------------------------------
UPDATE twist t
SET
    twist_package_id = ta.twist_package_id,
    publisher_id = ta.publisher_id,
    user_id = ta.user_id,
    auto_approve = ta.auto_approve
FROM twist_admin ta
WHERE t.twist_admin_id = ta.id;

-- Lock in new constraints.
ALTER TABLE "public"."twist"
    ALTER COLUMN "twist_package_id" SET NOT NULL,
    ADD CONSTRAINT "twist_owner_check" CHECK (
        (environment = 'personal'::public.twist_environment
            AND user_id IS NOT NULL
            AND publisher_id IS NULL)
        OR
        (environment <> 'personal'::public.twist_environment
            AND publisher_id IS NOT NULL
            AND user_id IS NULL)
    );

-- ---------------------------------------------------------------------------
-- Phase 5: Indexes on new columns.
-- ---------------------------------------------------------------------------
CREATE UNIQUE INDEX "idx_publisher_name_lower"
    ON "public"."publisher" (lower(name));

CREATE INDEX "idx_publisher_created_by"
    ON "public"."publisher" ("created_by");

CREATE INDEX "idx_twist_package_id"
    ON "public"."twist" ("twist_package_id");

CREATE INDEX "idx_twist_publisher_id"
    ON "public"."twist" ("publisher_id") WHERE publisher_id IS NOT NULL;

CREATE INDEX "idx_twist_user_id"
    ON "public"."twist" ("user_id") WHERE user_id IS NOT NULL;

CREATE UNIQUE INDEX "twist_personal_package_user_unique"
    ON "public"."twist" ("twist_package_id", "user_id")
    WHERE environment = 'personal'::public.twist_environment;

CREATE UNIQUE INDEX "twist_non_personal_package_environment_unique"
    ON "public"."twist" ("twist_package_id", "environment")
    WHERE environment <> 'personal'::public.twist_environment;

-- ---------------------------------------------------------------------------
-- Phase 6: Cross-environment publisher consistency trigger.
-- Enforces that all non-personal rows for the same twist_package_id agree on
-- publisher_id; API-layer topic check decides whether a user can claim an
-- unclaimed package for their publisher.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_twist_package_publisher_consistency ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_existing_publisher_id bigint;
BEGIN
    IF NEW.environment = 'personal' THEN
        RETURN NEW;
    END IF;

    SELECT publisher_id INTO v_existing_publisher_id
    FROM twist
    WHERE twist_package_id = NEW.twist_package_id
      AND environment <> 'personal'
      AND id <> COALESCE(NEW.id, -1)
    LIMIT 1;

    IF v_existing_publisher_id IS NOT NULL AND v_existing_publisher_id <> NEW.publisher_id THEN
        RAISE EXCEPTION 'twist_package_id % is already owned by publisher %, cannot assign to publisher %',
            NEW.twist_package_id, v_existing_publisher_id, NEW.publisher_id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER enforce_twist_package_publisher_consistency
    BEFORE INSERT OR UPDATE OF twist_package_id, publisher_id, environment ON "public"."twist"
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_twist_package_publisher_consistency ();

-- ---------------------------------------------------------------------------
-- Phase 7: New topic triggers.
-- ---------------------------------------------------------------------------
-- Replace user-topic function with rename-aware naming.
CREATE OR REPLACE FUNCTION public.auto_maintain_user_topic ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_topic_id uuid;
    v_contact_id uuid;
    v_user_name text;
    v_user_email text;
BEGIN
    SELECT id INTO v_topic_id FROM topic WHERE auto_user_id = NEW.user_id;
    IF v_topic_id IS NULL THEN
        SELECT "name", email INTO v_user_name, v_user_email FROM "user" WHERE id = NEW.user_id;
        INSERT INTO topic (name, type, auto_user_id, created_by, auto_maintained)
        VALUES (COALESCE(NULLIF(v_user_name, ''), split_part(v_user_email, '@', 1)) || '''s Account', 'private', NEW.user_id, NEW.user_id, TRUE)
        RETURNING id INTO v_topic_id;
    END IF;

    SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.user_id AND "primary" = TRUE AND linked = TRUE AND archived_at IS NULL;

    IF v_contact_id IS NOT NULL THEN
        INSERT INTO topic_member (topic_id, contact_id) VALUES (v_topic_id, v_contact_id) ON CONFLICT DO NOTHING;
    END IF;
    INSERT INTO topic_admin (topic_id, user_id) VALUES (v_topic_id, NEW.user_id) ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.auto_rename_user_topic ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE topic
    SET name = COALESCE(NULLIF(NEW."name", ''), split_part(NEW.email, '@', 1)) || '''s Account'
    WHERE auto_user_id = NEW.id
      AND auto_maintained = TRUE;
    RETURN NEW;
END;
$$;

CREATE TRIGGER auto_rename_user_topic
    AFTER UPDATE OF "name", email ON public."user"
    FOR EACH ROW
    WHEN (OLD."name" IS DISTINCT FROM NEW."name" OR OLD.email IS DISTINCT FROM NEW.email)
    EXECUTE FUNCTION public.auto_rename_user_topic ();

-- Publisher topic triggers.
CREATE OR REPLACE FUNCTION public.auto_maintain_publisher_topic ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_topic_id uuid;
    v_contact_id uuid;
BEGIN
    SELECT id INTO v_topic_id FROM topic WHERE auto_publisher_id = COALESCE(NEW.id, OLD.id);
    IF v_topic_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO topic (name, type, auto_publisher_id, created_by, auto_maintained)
        VALUES (NEW.name || ' Publisher', 'private', NEW.id, NEW.created_by, TRUE)
        RETURNING id INTO v_topic_id;
    END IF;

    IF v_topic_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.created_by IS DISTINCT FROM OLD.created_by) THEN
        SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.created_by AND "primary" = TRUE AND linked = TRUE AND archived_at IS NULL;
        IF v_contact_id IS NOT NULL THEN
            INSERT INTO topic_member (topic_id, contact_id) VALUES (v_topic_id, v_contact_id) ON CONFLICT DO NOTHING;
        END IF;
        INSERT INTO topic_admin (topic_id, user_id) VALUES (v_topic_id, NEW.created_by) ON CONFLICT DO NOTHING;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER auto_maintain_publisher_topic
    AFTER INSERT OR DELETE OR UPDATE OF created_by ON public.publisher
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_maintain_publisher_topic ();

CREATE OR REPLACE FUNCTION public.auto_rename_publisher_topic ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE topic
    SET name = NEW.name || ' Publisher'
    WHERE auto_publisher_id = NEW.id
      AND auto_maintained = TRUE;
    RETURN NEW;
END;
$$;

CREATE TRIGGER auto_rename_publisher_topic
    AFTER UPDATE OF name ON public.publisher
    FOR EACH ROW
    WHEN (OLD.name IS DISTINCT FROM NEW.name)
    EXECUTE FUNCTION public.auto_rename_publisher_topic ();

-- Personal-twist topic triggers.
CREATE OR REPLACE FUNCTION public.auto_maintain_personal_twist_topic ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_topic_id uuid;
    v_contact_id uuid;
    v_user_name text;
    v_user_email text;
BEGIN
    SELECT id INTO v_topic_id FROM topic WHERE auto_personal_twist_user_id = NEW.user_id;
    IF v_topic_id IS NULL THEN
        SELECT "name", email INTO v_user_name, v_user_email FROM "user" WHERE id = NEW.user_id;
        INSERT INTO topic (name, type, auto_personal_twist_user_id, created_by, auto_maintained)
        VALUES (COALESCE(NULLIF(v_user_name, ''), split_part(v_user_email, '@', 1)) || '''s Personal Twists', 'private', NEW.user_id, NEW.user_id, TRUE)
        RETURNING id INTO v_topic_id;
    END IF;

    SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.user_id AND "primary" = TRUE AND linked = TRUE AND archived_at IS NULL;

    IF v_contact_id IS NOT NULL THEN
        INSERT INTO topic_member (topic_id, contact_id) VALUES (v_topic_id, v_contact_id) ON CONFLICT DO NOTHING;
    END IF;
    INSERT INTO topic_admin (topic_id, user_id) VALUES (v_topic_id, NEW.user_id) ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER auto_maintain_personal_twist_topic
    AFTER INSERT OR UPDATE OF "primary", linked, archived_at ON public.user_contact
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_maintain_personal_twist_topic ();

CREATE OR REPLACE FUNCTION public.auto_rename_personal_twist_topic ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE topic
    SET name = COALESCE(NULLIF(NEW."name", ''), split_part(NEW.email, '@', 1)) || '''s Personal Twists'
    WHERE auto_personal_twist_user_id = NEW.id
      AND auto_maintained = TRUE;
    RETURN NEW;
END;
$$;

CREATE TRIGGER auto_rename_personal_twist_topic
    AFTER UPDATE OF "name", email ON public."user"
    FOR EACH ROW
    WHEN (OLD."name" IS DISTINCT FROM NEW."name" OR OLD.email IS DISTINCT FROM NEW.email)
    EXECUTE FUNCTION public.auto_rename_personal_twist_topic ();

-- ---------------------------------------------------------------------------
-- Phase 8: Topic index churn.
-- ---------------------------------------------------------------------------
-- Drop any auto-maintained topics tied to the twist_admin table. Phase 13
-- drops the auto_twist_admin_id column, which would otherwise leave these
-- rows as orphans that match the new idx_topic_auto_everyone predicate with
-- every column NULL.
DELETE FROM public.topic WHERE auto_twist_admin_id IS NOT NULL;

DROP INDEX IF EXISTS "public"."idx_topic_auto_everyone";

CREATE UNIQUE INDEX "idx_topic_auto_publisher"
    ON "public"."topic" ("auto_publisher_id")
    WHERE auto_maintained = TRUE AND auto_publisher_id IS NOT NULL;

CREATE UNIQUE INDEX "idx_topic_auto_personal_twist_user"
    ON "public"."topic" ("auto_personal_twist_user_id")
    WHERE auto_maintained = TRUE AND auto_personal_twist_user_id IS NOT NULL;

CREATE UNIQUE INDEX "idx_topic_auto_everyone"
    ON "public"."topic" ("auto_maintained")
    WHERE auto_maintained = TRUE
      AND team_id IS NULL
      AND auto_user_id IS NULL
      AND auto_publisher_id IS NULL
      AND auto_personal_twist_user_id IS NULL;

-- ---------------------------------------------------------------------------
-- Phase 9: Data migration — per-user personal-twist topics + members/admins.
-- ---------------------------------------------------------------------------
INSERT INTO topic (name, type, auto_personal_twist_user_id, created_by, auto_maintained)
SELECT COALESCE(NULLIF(u.name, ''), split_part(u.email, '@', 1)) || '''s Personal Twists',
       'private', u.id, u.id, TRUE
FROM "public"."user" u
WHERE NOT EXISTS (SELECT 1 FROM topic WHERE auto_personal_twist_user_id = u.id);

INSERT INTO topic_member (topic_id, contact_id)
SELECT t.id, uc.contact_id
FROM topic t
JOIN user_contact uc ON uc.user_id = t.auto_personal_twist_user_id
    AND uc."primary" = TRUE AND uc.linked = TRUE AND uc.archived_at IS NULL
WHERE t.auto_personal_twist_user_id IS NOT NULL
ON CONFLICT DO NOTHING;

INSERT INTO topic_admin (topic_id, user_id)
SELECT t.id, t.auto_personal_twist_user_id
FROM topic t
WHERE t.auto_personal_twist_user_id IS NOT NULL
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Phase 10: Data migration — publisher topics + members/admins.
-- Seed topic for every existing publisher, with created_by as first admin.
-- ---------------------------------------------------------------------------
INSERT INTO topic (name, type, auto_publisher_id, created_by, auto_maintained)
SELECT p.name || ' Publisher', 'private', p.id, p.created_by, TRUE
FROM publisher p
WHERE NOT EXISTS (SELECT 1 FROM topic WHERE auto_publisher_id = p.id);

INSERT INTO topic_member (topic_id, contact_id)
SELECT t.id, uc.contact_id
FROM topic t
JOIN publisher p ON p.id = t.auto_publisher_id
JOIN user_contact uc ON uc.user_id = p.created_by
    AND uc."primary" = TRUE AND uc.linked = TRUE AND uc.archived_at IS NULL
WHERE t.auto_publisher_id IS NOT NULL
ON CONFLICT DO NOTHING;

INSERT INTO topic_admin (topic_id, user_id)
SELECT t.id, p.created_by
FROM topic t
JOIN publisher p ON p.id = t.auto_publisher_id
WHERE t.auto_publisher_id IS NOT NULL
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Phase 11: Priority rules — route new topics into @plot.twist-dev.
-- ---------------------------------------------------------------------------
INSERT INTO priority_rule (user_id, priority_id, type, criteria)
SELECT u.id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
FROM "public"."user" u
JOIN priority p ON p.user_id = u.id AND p.key = '@plot.twist-dev'
JOIN topic t ON t.auto_personal_twist_user_id = u.id
ON CONFLICT DO NOTHING;

INSERT INTO priority_rule (user_id, priority_id, type, criteria)
SELECT uc.user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
FROM topic t
JOIN topic_member tm ON tm.topic_id = t.id
JOIN user_contact uc ON uc.contact_id = tm.contact_id
JOIN priority p ON p.user_id = uc.user_id AND p.key = '@plot.twist-dev'
WHERE t.auto_publisher_id IS NOT NULL
  AND t.auto_maintained = TRUE
  AND uc.linked = TRUE AND uc.archived_at IS NULL
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------
-- Phase 12: Mint publisher token for Plot (CI deploy token).
-- The raw token is stored in token.token for retrieval via direct DB query
-- after the migration runs:
--   SELECT token FROM token
--   WHERE name = 'Plot Publisher (CI)' AND archived_at IS NULL;
-- It is intentionally NOT surfaced via RAISE NOTICE to keep it out of CI logs.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_plot_id bigint;
    v_token text;
BEGIN
    SELECT id INTO v_plot_id FROM publisher WHERE lower(name) = 'plot' LIMIT 1;

    IF v_plot_id IS NULL THEN
        RAISE NOTICE 'No Plot publisher found — skipping publisher token';
        RETURN;
    END IF;

    -- Idempotent: skip if a CI token already exists for this publisher.
    IF EXISTS (
        SELECT 1 FROM token
        WHERE publisher_id = v_plot_id
          AND name = 'Plot Publisher (CI)'
          AND archived_at IS NULL
    ) THEN
        RAISE NOTICE 'Plot publisher CI token already exists — skipping mint';
        RETURN;
    END IF;

    v_token := 'plot_pub_' || encode(extensions.gen_random_bytes(32), 'base64');
    -- Strip any base64 '=' padding and '/' for URL safety.
    v_token := translate(v_token, '+/=', '-_');

    INSERT INTO token (publisher_id, token, name)
    VALUES (v_plot_id, v_token, 'Plot Publisher (CI)');

    RAISE NOTICE 'Plot publisher CI token minted; retrieve via SELECT on token table';
END $$;

-- ---------------------------------------------------------------------------
-- Phase 13: Drop the old table / column / function.
-- ---------------------------------------------------------------------------
ALTER TABLE "public"."twist" DROP COLUMN "twist_admin_id";
ALTER TABLE "public"."topic" DROP COLUMN "auto_twist_admin_id";
DROP TABLE "public"."twist_admin";
DROP FUNCTION IF EXISTS "public"."auto_maintain_twist_admin_topic"();

-- ---------------------------------------------------------------------------
-- Phase 14: Replace dependent views/functions with publisher-based versions.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_accessible_twists (p_user_id uuid)
    RETURNS SETOF twist
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT DISTINCT twist.*
    FROM twist
    WHERE twist.archived_at IS NULL
      AND (
          twist.environment = 'public'
          OR (twist.environment = 'personal' AND twist.user_id = p_user_id)
          OR (twist.environment = 'review'
              AND EXISTS (SELECT 1 FROM twist_reviewer WHERE user_id = p_user_id))
          OR (twist.publisher_id IS NOT NULL AND EXISTS (
              SELECT 1 FROM topic t
              JOIN topic_member tm ON tm.topic_id = t.id
              JOIN user_contact uc ON uc.contact_id = tm.contact_id
              WHERE t.auto_publisher_id = twist.publisher_id
                AND t.auto_maintained = TRUE
                AND uc.user_id = p_user_id
                AND uc.linked = TRUE
                AND uc.archived_at IS NULL
          ))
      )
$function$;

CREATE OR REPLACE FUNCTION public.is_accessible_twist (p_twist_id bigint, p_user_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM twist
        WHERE twist.id = p_twist_id
          AND twist.archived_at IS NULL
          AND (
              twist.environment = 'public'
              OR (twist.environment = 'personal' AND twist.user_id = p_user_id)
              OR (twist.environment = 'review'
                  AND EXISTS (SELECT 1 FROM twist_reviewer WHERE user_id = p_user_id))
              OR (twist.publisher_id IS NOT NULL AND EXISTS (
                  SELECT 1 FROM topic t
                  JOIN topic_member tm ON tm.topic_id = t.id
                  JOIN user_contact uc ON uc.contact_id = tm.contact_id
                  WHERE t.auto_publisher_id = twist.publisher_id
                    AND t.auto_maintained = TRUE
                    AND uc.user_id = p_user_id
                    AND uc.linked = TRUE
                    AND uc.archived_at IS NULL
              ))
          )
    )
$function$;

CREATE OR REPLACE VIEW "public"."priority_child_twist"
AS
SELECT
    pt.*,
    t.version,
    t.environment AS twist_environment,
    t.is_source,
    p.name AS author_name,
    p.email AS author_email,
    p.url AS author_url
FROM twist_instance pt
    JOIN twist t ON pt.twist_id = t.id
    LEFT JOIN publisher p ON t.publisher_id = p.id
WHERE pt.archived_at IS NULL;

-- Re-create twist_instance_thread_tag_change (CASCADE from priority_child_twist drop
-- dropped this view, so restore it unchanged).
CREATE OR REPLACE VIEW "public"."twist_instance_thread_tag_change"
AS
SELECT
    a.created_by AS twist_instance_id,
    at.thread_id,
    at.occurrence,
    at.tag_id,
    at.actor_id,
    at.updated_at,
    CASE WHEN at.archived_at IS NULL THEN
        'added'
    ELSE
        'removed'
    END AS change_type
FROM
    thread_tag at
    JOIN thread a ON a.id = at.thread_id
    JOIN priority_child_twist pct ON pct.id = a.created_by
WHERE
    a.draft = FALSE;

CREATE OR REPLACE VIEW "user"."twist"
AS
SELECT
    pt.owner_id AS user_id,
    pt.id,
    pt.created_at,
    GREATEST(pt.updated_at, t.updated_at, (
        SELECT MAX(ptc2.connected_at)
        FROM twist_instance_connection ptc2
        WHERE ptc2.twist_instance_id = pt.id
          AND ptc2.user_id = pt.owner_id
    )) AS updated_at,
    pt.archived_at,
    pt.twist_id,
    t.environment AS twist_environment,
    t.is_source,
    t.multiple_instances,
    t.shared,
    t.key_option,
    pt.owner_id,
    pt.name,
    pt.options,
    t.logo_url,
    t.logo_url_dark,
    (
        SELECT jsonb_agg(lt)
        FROM jsonb_array_elements(t.permissions -> '_providers') AS p,
             jsonb_array_elements(p -> 'linkTypes') AS lt
    ) AS link_types,
    COALESCE((t.permissions ->> '_default_mention_created')::boolean, false) AS default_mention_created,
    COALESCE((t.permissions ->> '_default_mention_mentioned')::boolean, false) AS default_mention_mentioned,
    CASE
        WHEN t.shared THEN EXISTS (
            SELECT 1 FROM twist_instance_connection ptc
            WHERE ptc.twist_instance_id = pt.id
        )
        ELSE EXISTS (
            SELECT 1 FROM twist_instance_connection ptc
            WHERE ptc.twist_instance_id = pt.id
              AND ptc.user_id = pt.owner_id
        )
    END AS user_connected,
    (t.twist_package_id = '0199b6f4-ae64-7718-8a02-44716f30358f') AS is_builtin
FROM twist_instance pt
    JOIN twist t ON pt.twist_id = t.id;

-- ---------------------------------------------------------------------------
-- Phase 15: Refresh activate_invited_user to reference the new topics.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION "public"."activate_invited_user" ("p_user_id" uuid)
    RETURNS jsonb
    LANGUAGE plpgsql
    SET "search_path" = public
    AS $$
DECLARE
    v_root_priority_id uuid;
    v_new_path ltree;
BEGIN
    SELECT id INTO v_root_priority_id
    FROM public.priority
    WHERE user_id = p_user_id
      AND nlevel(path) = 1
    ORDER BY created_at ASC
    LIMIT 1;

    IF v_root_priority_id IS NOT NULL THEN
        RETURN jsonb_build_object('activated', FALSE, 'already_active', TRUE, 'root_priority_id', v_root_priority_id);
    END IF;

    v_new_path := generate_path(NULL);
    INSERT INTO public.priority (created_by, user_id, title, path, color)
        VALUES (p_user_id, p_user_id, 'Everything', v_new_path, 0)
    RETURNING id INTO v_root_priority_id;

    INSERT INTO public.priority (created_by, user_id, title, path, color, key, default_thread_icon)
    VALUES (p_user_id, p_user_id, 'Using Plot', v_new_path || generate_path(NULL), 7, '@plot.app', 'https://plot.day/assets/plot-icon.svg');

    INSERT INTO public.priority (created_by, user_id, title, path, color, key)
    VALUES (p_user_id, p_user_id, 'Twist Development', v_new_path || generate_path(NULL), 3, '@plot.twist-dev');

    -- 1. Everyone topic -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND t.auto_maintained = TRUE AND t.team_id IS NULL AND t.name = 'Everyone';

    -- 2. User account topic -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND t.auto_user_id = p_user_id;

    -- 3. Team admin topics -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    JOIN public.team_user tu ON tu.team_id = t.auto_team_admin_team_id AND tu.user_id = p_user_id
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND t.auto_team_admin_team_id IS NOT NULL;

    -- 4. Personal twists topic -> Twist Development
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    WHERE p.user_id = p_user_id AND p.key = '@plot.twist-dev'
      AND t.auto_personal_twist_user_id = p_user_id;

    -- 5. Publisher topics (where this user is a member) -> Twist Development
    INSERT INTO public.priority_rule (user_id, priority_id, type, criteria)
    SELECT p_user_id, p.id, 'contact_topics', jsonb_build_object('topics', ARRAY[t.id::text])
    FROM public.priority p
    CROSS JOIN public.topic t
    JOIN public.topic_member tm ON tm.topic_id = t.id
    JOIN public.user_contact uc ON uc.contact_id = tm.contact_id
    WHERE p.user_id = p_user_id AND p.key = '@plot.twist-dev'
      AND t.auto_publisher_id IS NOT NULL
      AND t.auto_maintained = TRUE
      AND uc.user_id = p_user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$$;

-- Fix link.twist_id comment (no longer references twist_admin).
COMMENT ON COLUMN "public"."link"."twist_id" IS 'The twist definition ID (twist.id) that created this link. Null for user-created links.';
