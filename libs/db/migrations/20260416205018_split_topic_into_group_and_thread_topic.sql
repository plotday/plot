-- =============================================================================
-- Split `topic` into `group` (contact grouping) + `thread.topic` (routing key).
--
-- Preserves all existing data where possible:
--   - topic/topic_member/topic_admin tables are renamed (not dropped) so rows
--     survive.
--   - thread.topics is renamed to thread.groups.
--   - thread.topic is backfilled from groups[1] and channel links.
--   - priority_rule rows are migrated from (channel | contact_topics) to the
--     new `topic` shape.
--   - auto_user_id / auto_personal_twist_user_id rows are deleted (rows, not
--     data carried forward) because those single-contact groups are being
--     replaced by thread.topic strings.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Drop objects that reference the old names (views, triggers, functions).
-- They are recreated below from the renamed tables and the new schema.
-- ---------------------------------------------------------------------------

DROP VIEW IF EXISTS "user"."thread_tags" CASCADE;
DROP VIEW IF EXISTS "user"."thread" CASCADE;
DROP VIEW IF EXISTS "user"."note" CASCADE;
DROP VIEW IF EXISTS "user"."note_redacted" CASCADE;
DROP VIEW IF EXISTS "user"."note_tags" CASCADE;
DROP VIEW IF EXISTS "user"."topic" CASCADE;

DROP TRIGGER IF EXISTS user_sync_topic_insert ON topic;
DROP TRIGGER IF EXISTS user_sync_topic_update ON topic;

DROP TRIGGER IF EXISTS auto_create_team_topic ON team;
DROP TRIGGER IF EXISTS auto_maintain_team_topic_members ON team_user;
DROP TRIGGER IF EXISTS auto_maintain_team_admin_topic ON team_user;
DROP TRIGGER IF EXISTS auto_maintain_user_topic ON user_contact;
DROP TRIGGER IF EXISTS auto_rename_user_topic ON "user";
DROP TRIGGER IF EXISTS auto_maintain_personal_twist_topic ON user_contact;
DROP TRIGGER IF EXISTS auto_rename_personal_twist_topic ON "user";
DROP TRIGGER IF EXISTS auto_maintain_publisher_topic ON publisher;
DROP TRIGGER IF EXISTS auto_rename_publisher_topic ON publisher;
DROP TRIGGER IF EXISTS auto_maintain_everyone_topic ON user_contact;

DROP TRIGGER IF EXISTS file_thread_priority_for_topic_members ON thread;
DROP TRIGGER IF EXISTS file_thread_priority_on_topic_member_change ON topic_member;

DROP FUNCTION IF EXISTS public.sync_user_for_topic() CASCADE;
DROP FUNCTION IF EXISTS public.auto_create_team_topic() CASCADE;
DROP FUNCTION IF EXISTS public.auto_maintain_team_topic_members() CASCADE;
DROP FUNCTION IF EXISTS public.auto_maintain_team_admin_topic() CASCADE;
DROP FUNCTION IF EXISTS public.auto_maintain_user_topic() CASCADE;
DROP FUNCTION IF EXISTS public.auto_rename_user_topic() CASCADE;
DROP FUNCTION IF EXISTS public.auto_maintain_personal_twist_topic() CASCADE;
DROP FUNCTION IF EXISTS public.auto_rename_personal_twist_topic() CASCADE;
DROP FUNCTION IF EXISTS public.auto_maintain_publisher_topic() CASCADE;
DROP FUNCTION IF EXISTS public.auto_rename_publisher_topic() CASCADE;
DROP FUNCTION IF EXISTS public.auto_maintain_everyone_topic() CASCADE;
DROP FUNCTION IF EXISTS public.file_thread_priority_for_topic_members() CASCADE;
DROP FUNCTION IF EXISTS public.file_thread_priority_on_topic_member_change() CASCADE;

DROP FUNCTION IF EXISTS public.create_topic(uuid, text, topic_type, topic_join_policy, bigint, uuid[]) CASCADE;
DROP FUNCTION IF EXISTS public.add_topic_members(uuid, uuid, uuid[]) CASCADE;
DROP FUNCTION IF EXISTS public.remove_topic_members(uuid, uuid, uuid[]) CASCADE;
DROP FUNCTION IF EXISTS public.share_thread_with_topics(uuid, uuid, uuid[], uuid[]) CASCADE;
DROP FUNCTION IF EXISTS "user".user_topic_ids(uuid) CASCADE;

-- Replace the signatures of functions that take thread.topics-shaped args.
DROP FUNCTION IF EXISTS public.classify_thread_for_user(uuid, uuid, halfvec, uuid[], uuid[], bigint) CASCADE;
DROP FUNCTION IF EXISTS public.classify_thread_for_user(uuid, uuid, halfvec, uuid[], uuid[]) CASCADE;

-- ---------------------------------------------------------------------------
-- Clean up data that's being removed.
-- ---------------------------------------------------------------------------

-- Delete single-contact auto topics (account + personal-twists). CASCADE
-- cleans up topic_member / topic_admin rows; thread.topics arrays still
-- reference these ids and are cleaned up below.
DELETE FROM topic
WHERE auto_user_id IS NOT NULL
   OR auto_personal_twist_user_id IS NOT NULL;

-- Strip any now-dangling topic ids from thread.topics so the rename-to-groups
-- doesn't drag dangling references forward.
UPDATE thread t
SET topics = ARRAY(
    SELECT x FROM unnest(t.topics) AS x
    WHERE EXISTS (SELECT 1 FROM topic WHERE id = x)
)
WHERE NOT (t.topics <@ (SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) FROM topic));

-- Migrate existing priority_rule rows from (channel | contact_topics) to the
-- new `topic` shape. We do this before altering the CHECK constraint and
-- before dropping channel_id / criteria.
--   channel:          -> topic = 'channel:' || channel_id::text
--   contact_topics:   -> one row per topic uuid in criteria.topics, plus one
--                        row per contact uuid in criteria.contacts
-- We UPDATE the first row in-place (preserves id / created_at / label) and
-- INSERT extra rows as needed for additional ids.

-- Add the new column first so we can fill it in-place.
ALTER TABLE priority_rule ADD COLUMN topic text;

-- Drop the old CHECK constraint so we can rewrite the `type` column to 'topic'.
-- We re-add it below after rows are migrated and channel_id/criteria are dropped.
ALTER TABLE priority_rule DROP CONSTRAINT priority_rule_type_check;

-- 1) channel rules: one-to-one rewrite.
UPDATE priority_rule
SET type = 'topic',
    topic = 'channel:' || channel_id::text
WHERE type = 'channel'
  AND channel_id IS NOT NULL;

-- 2) contact_topics rules: the "primary" uuid (first in topics, else first
--    in contacts) becomes this row's topic. Any remaining uuids are inserted
--    as sibling rows below.
WITH primaries AS (
    SELECT pr.id,
        COALESCE(
            (pr.criteria -> 'topics' ->> 0),
            (pr.criteria -> 'contacts' ->> 0)
        ) AS first_uuid
    FROM priority_rule pr
    WHERE pr.type = 'contact_topics'
)
UPDATE priority_rule pr
SET type = 'topic',
    topic = p.first_uuid
FROM primaries p
WHERE pr.id = p.id
  AND p.first_uuid IS NOT NULL;

-- Insert additional rows for the remaining uuids in each contact_topics rule.
INSERT INTO priority_rule (user_id, priority_id, type, topic, label, anchor_thread_id)
SELECT pr.user_id, pr.priority_id, 'topic', extra.uuid_text, pr.label, pr.anchor_thread_id
FROM priority_rule pr,
    LATERAL (
        SELECT val AS uuid_text, ord
        FROM jsonb_array_elements_text(COALESCE(pr.criteria -> 'topics', '[]'::jsonb)) WITH ORDINALITY AS t(val, ord)
        WHERE ord > 1
        UNION ALL
        SELECT val AS uuid_text,
            ord + COALESCE(jsonb_array_length(pr.criteria -> 'topics'), 0) AS ord
        FROM jsonb_array_elements_text(COALESCE(pr.criteria -> 'contacts', '[]'::jsonb)) WITH ORDINALITY AS c(val, ord)
        WHERE NOT (
            pr.criteria -> 'topics' IS NULL
            OR jsonb_array_length(pr.criteria -> 'topics') = 0
        )
        OR ord > 1
    ) AS extra
WHERE pr.type = 'topic'  -- rows already rewritten above
  AND pr.criteria IS NOT NULL
  AND (
    jsonb_array_length(COALESCE(pr.criteria -> 'topics', '[]'::jsonb)) > 1
    OR (
      pr.criteria -> 'contacts' IS NOT NULL
      AND jsonb_array_length(pr.criteria -> 'contacts') > 0
    )
  );

-- Delete any contact_topics rules that survived without a topic (empty criteria).
DELETE FROM priority_rule WHERE type = 'contact_topics';

-- Drop channel_id / criteria columns and add the new CHECK constraint.
ALTER TABLE priority_rule
    ADD CONSTRAINT priority_rule_type_check CHECK (type IN ('content', 'topic')),
    DROP COLUMN channel_id,
    DROP COLUMN criteria;

CREATE INDEX idx_priority_rule_user_topic
    ON priority_rule (user_id, topic)
    WHERE topic IS NOT NULL;

COMMENT ON TABLE priority_rule IS 'User-defined rules for automatically filing threads into priorities. Evaluated in precedence order: content > topic > root fallback.';
COMMENT ON COLUMN priority_rule.topic IS 'Exact-string match target for thread.topic. Examples: channel:42 (connector channel), a group uuid, or any caller-supplied string.';

-- ---------------------------------------------------------------------------
-- Rename enums.
-- ---------------------------------------------------------------------------

ALTER TYPE topic_type RENAME TO group_type;
ALTER TYPE topic_join_policy RENAME TO group_join_policy;

-- ---------------------------------------------------------------------------
-- Rename tables, columns, indexes, and constraints.
-- ---------------------------------------------------------------------------

ALTER TABLE topic RENAME TO "group";
ALTER TABLE topic_member RENAME TO group_member;
ALTER TABLE topic_admin RENAME TO group_admin;

ALTER TABLE group_member RENAME COLUMN topic_id TO group_id;
ALTER TABLE group_admin RENAME COLUMN topic_id TO group_id;

-- Drop columns that had partial-unique indexes we're getting rid of.
ALTER TABLE "group" DROP COLUMN auto_user_id;
ALTER TABLE "group" DROP COLUMN auto_personal_twist_user_id;

-- Rename indexes to match new table name. The partial-unique indexes on
-- auto_user_id / auto_personal_twist_user_id were auto-dropped when we
-- dropped those columns above, so we skip them here. idx_topic_auto_everyone
-- referenced those dropped columns in its WHERE predicate; recreate it from
-- scratch with the new narrower predicate.
ALTER INDEX topic_pkey RENAME TO group_pkey;
ALTER INDEX idx_topic_team_id RENAME TO idx_group_team_id;
ALTER INDEX idx_topic_updated_at RENAME TO idx_group_updated_at;
ALTER INDEX idx_topic_auto_team RENAME TO idx_group_auto_team;
ALTER INDEX idx_topic_auto_team_admin RENAME TO idx_group_auto_team_admin;
ALTER INDEX idx_topic_auto_publisher RENAME TO idx_group_auto_publisher;

DROP INDEX IF EXISTS idx_topic_auto_everyone;
CREATE UNIQUE INDEX idx_group_auto_everyone ON "group" (auto_maintained)
WHERE auto_maintained = TRUE
  AND team_id IS NULL
  AND auto_publisher_id IS NULL;

ALTER INDEX topic_member_pkey RENAME TO group_member_pkey;
ALTER INDEX idx_topic_member_contact_id RENAME TO idx_group_member_contact_id;

ALTER INDEX topic_admin_pkey RENAME TO group_admin_pkey;
ALTER INDEX idx_topic_admin_user_id RENAME TO idx_group_admin_user_id;

-- Rename the table's updated_at/created_at row triggers.
ALTER TRIGGER set_topic_updated_at ON "group" RENAME TO set_group_updated_at;
ALTER TRIGGER set_topic_created_at ON "group" RENAME TO set_group_created_at;
ALTER TRIGGER set_topic_member_updated_at ON group_member RENAME TO set_group_member_updated_at;
ALTER TRIGGER set_topic_member_created_at ON group_member RENAME TO set_group_member_created_at;

-- Refresh comments.
COMMENT ON TABLE "group" IS 'Named groups of contacts. Groups can be added to threads for dynamic visibility — adding a member retroactively grants access to all threads the group is on.';
COMMENT ON COLUMN "group".auto_maintained IS 'TRUE for system-managed groups (Everyone, team groups). Membership is maintained by triggers and cannot be modified via API.';

-- ---------------------------------------------------------------------------
-- thread: rename topics->groups, add topic, backfill, reindex.
-- ---------------------------------------------------------------------------

ALTER TABLE thread RENAME COLUMN topics TO groups;
ALTER TABLE thread ADD COLUMN topic text;

ALTER INDEX idx_thread_topics RENAME TO idx_thread_groups;

CREATE INDEX idx_thread_topic ON thread (topic) WHERE topic IS NOT NULL;

-- Backfill thread.topic:
--   Prefer channel:<channel.id> for threads linked to a channel source.
--   Fall back to the first group id (stringified) when the thread has groups.
UPDATE thread t
SET topic = 'channel:' || c.id::text
FROM link l
JOIN channel c
    ON c.twist_instance_id = l.created_by
   AND c.channel_id = l.channel_id
WHERE l.thread_id = t.id
  AND l.channel_id IS NOT NULL
  AND t.topic IS NULL;

UPDATE thread
SET topic = groups[1]::text
WHERE topic IS NULL
  AND cardinality(groups) > 0;

COMMENT ON COLUMN thread.groups IS 'Group IDs attached to this thread. Members of referenced groups gain visibility dynamically — new members automatically see past threads.';
COMMENT ON COLUMN thread.topic IS 'Routing key used by priority rules. On INSERT defaults to, in order: explicit input, channel:<channel.id> when the thread comes from a connection, or groups[1]::text.';

-- ---------------------------------------------------------------------------
-- Recreate group-related functions / triggers with new names.
-- ---------------------------------------------------------------------------

-- user.user_group_ids
CREATE OR REPLACE FUNCTION "user".user_group_ids (p_user_id uuid)
    RETURNS uuid[]
    LANGUAGE sql
    STABLE
    AS $$
    SELECT COALESCE(array_agg(DISTINCT gm.group_id), ARRAY[]::uuid[])
    FROM group_member gm
    JOIN user_contact uc ON uc.contact_id = gm.contact_id
        AND uc.linked = TRUE
        AND uc.archived_at IS NULL
    WHERE uc.user_id = p_user_id;
$$;

-- public.create_group / add_group_members / remove_group_members
CREATE OR REPLACE FUNCTION public.create_group (
    p_user_id uuid,
    p_name text,
    p_type group_type DEFAULT 'private',
    p_join_policy group_join_policy DEFAULT 'member',
    p_team_id bigint DEFAULT NULL,
    p_member_contact_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
    RETURNS uuid
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_group_id uuid;
BEGIN
    IF p_team_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM team_user
            WHERE team_id = p_team_id AND user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'User is not a member of this team';
        END IF;
    END IF;

    INSERT INTO "group" (name, type, join_policy, team_id, created_by)
    VALUES (p_name, p_type, p_join_policy, p_team_id, p_user_id)
    RETURNING id INTO v_group_id;

    INSERT INTO group_admin (group_id, user_id)
    VALUES (v_group_id, p_user_id);

    IF cardinality(p_member_contact_ids) > 0 THEN
        INSERT INTO group_member (group_id, contact_id)
        SELECT v_group_id, unnest(p_member_contact_ids)
        ON CONFLICT DO NOTHING;
    END IF;

    RETURN v_group_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.add_group_members (
    p_user_id uuid,
    p_group_id uuid,
    p_contact_ids uuid[]
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_group RECORD;
BEGIN
    SELECT * INTO v_group FROM "group" WHERE id = p_group_id;
    IF v_group IS NULL THEN
        RAISE EXCEPTION 'Group not found';
    END IF;
    IF v_group.auto_maintained THEN
        RAISE EXCEPTION 'Cannot modify members of auto-maintained group';
    END IF;

    IF v_group.join_policy = 'admin' THEN
        IF NOT EXISTS (
            SELECT 1 FROM group_admin
            WHERE group_id = p_group_id AND user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'Only admins can add members to this group';
        END IF;
    ELSIF v_group.join_policy = 'member' THEN
        IF NOT EXISTS (
            SELECT 1 FROM group_admin
            WHERE group_id = p_group_id AND user_id = p_user_id
        ) AND NOT EXISTS (
            SELECT 1 FROM group_member gm
            JOIN user_contact uc ON uc.contact_id = gm.contact_id
                AND uc.linked = TRUE AND uc.archived_at IS NULL
            WHERE gm.group_id = p_group_id AND uc.user_id = p_user_id
        ) THEN
            RAISE EXCEPTION 'Only members can add members to this group';
        END IF;
    END IF;

    INSERT INTO group_member (group_id, contact_id)
    SELECT p_group_id, unnest(p_contact_ids)
    ON CONFLICT DO NOTHING;
END;
$function$;

CREATE OR REPLACE FUNCTION public.remove_group_members (
    p_user_id uuid,
    p_group_id uuid,
    p_contact_ids uuid[]
)
    RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_group RECORD;
BEGIN
    SELECT * INTO v_group FROM "group" WHERE id = p_group_id;
    IF v_group IS NULL THEN
        RAISE EXCEPTION 'Group not found';
    END IF;
    IF v_group.auto_maintained THEN
        RAISE EXCEPTION 'Cannot modify members of auto-maintained group';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM group_admin
        WHERE group_id = p_group_id AND user_id = p_user_id
    ) AND NOT EXISTS (
        SELECT 1 FROM group_member gm
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE gm.group_id = p_group_id AND uc.user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'Insufficient permission to remove group members';
    END IF;

    DELETE FROM group_member
    WHERE group_id = p_group_id AND contact_id = ANY(p_contact_ids);
END;
$function$;

-- share_thread_with_groups
CREATE OR REPLACE FUNCTION public.share_thread_with_groups (
    p_user_id uuid,
    p_thread_id uuid,
    p_add_group_ids uuid[] DEFAULT ARRAY[]::uuid[],
    p_remove_group_ids uuid[] DEFAULT ARRAY[]::uuid[]
)
    RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_current_groups uuid[];
    v_new_groups uuid[];
    v_group RECORD;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM thread_priority tp
        WHERE tp.thread_id = p_thread_id
          AND tp.user_id = p_user_id
    ) THEN
        RAISE EXCEPTION 'User does not have access to this thread';
    END IF;

    FOR v_group IN
        SELECT g.id, g.type
        FROM unnest(p_add_group_ids) AS arr(id)
        JOIN "group" g ON g.id = arr.id
        WHERE g.archived_at IS NULL
    LOOP
        IF v_group.type = 'announce' THEN
            IF NOT EXISTS (
                SELECT 1 FROM group_admin
                WHERE group_id = v_group.id AND user_id = p_user_id
            ) THEN
                RAISE EXCEPTION 'Only admins can add announce groups to threads';
            END IF;
        ELSIF v_group.type IN ('private', 'team') THEN
            IF NOT EXISTS (
                SELECT 1 FROM group_admin
                WHERE group_id = v_group.id AND user_id = p_user_id
            ) AND NOT EXISTS (
                SELECT 1 FROM group_member gm
                JOIN user_contact uc ON uc.contact_id = gm.contact_id
                    AND uc.linked = TRUE AND uc.archived_at IS NULL
                WHERE gm.group_id = v_group.id AND uc.user_id = p_user_id
            ) THEN
                RAISE EXCEPTION 'User does not have permission to add this group';
            END IF;
        END IF;
    END LOOP;

    SELECT groups INTO v_current_groups
    FROM thread
    WHERE id = p_thread_id;

    IF v_current_groups IS NULL THEN
        v_current_groups := ARRAY[]::uuid[];
    END IF;

    SELECT COALESCE(array_agg(DISTINCT gid), ARRAY[]::uuid[])
    INTO v_new_groups
    FROM (
        SELECT unnest(v_current_groups) AS gid
        UNION
        SELECT unnest(p_add_group_ids)
    ) all_groups
    WHERE gid != ALL(COALESCE(p_remove_group_ids, ARRAY[]::uuid[]));

    UPDATE thread
    SET groups = v_new_groups
    WHERE id = p_thread_id;

    RETURN jsonb_build_object('groups', to_jsonb(v_new_groups));
END;
$function$;

-- classify_thread_for_user (new signature)
CREATE OR REPLACE FUNCTION public.classify_thread_for_user (
    p_user_id uuid,
    p_thread_id uuid DEFAULT NULL,
    p_embedding halfvec DEFAULT NULL,
    p_topic text DEFAULT NULL
)
    RETURNS uuid
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_embedding halfvec;
    v_topic text;
    v_matched_priority_id uuid;
    v_root_priority_id uuid;
BEGIN
    IF p_thread_id IS NOT NULL THEN
        SELECT t.embedding, t.topic
        INTO v_embedding, v_topic
        FROM public.thread t
        WHERE t.id = p_thread_id;
    END IF;

    v_embedding := COALESCE(p_embedding, v_embedding);
    v_topic     := COALESCE(p_topic, v_topic);

    IF v_embedding IS NOT NULL THEN
        SELECT pr.priority_id INTO v_matched_priority_id
        FROM public.priority_rule pr
        WHERE pr.user_id = p_user_id
          AND pr.type = 'content'
          AND pr.embedding IS NOT NULL
          AND (1 - (pr.embedding <=> v_embedding)) >= 0.7
        ORDER BY (1 - (pr.embedding <=> v_embedding)) DESC
        LIMIT 1;

        IF v_matched_priority_id IS NOT NULL THEN
            RETURN v_matched_priority_id;
        END IF;
    END IF;

    IF v_topic IS NOT NULL THEN
        SELECT pr.priority_id INTO v_matched_priority_id
        FROM public.priority_rule pr
        WHERE pr.user_id = p_user_id
          AND pr.type = 'topic'
          AND pr.topic = v_topic
        ORDER BY pr.created_at ASC
        LIMIT 1;

        IF v_matched_priority_id IS NOT NULL THEN
            RETURN v_matched_priority_id;
        END IF;
    END IF;

    SELECT p.id INTO v_root_priority_id
    FROM public.priority p
    WHERE p.user_id = p_user_id
      AND nlevel(p.path) = 1
      AND p.archived_at IS NULL
    ORDER BY p.created_at ASC
    LIMIT 1;

    RETURN v_root_priority_id;
END;
$function$;

COMMENT ON FUNCTION public.classify_thread_for_user IS 'Classify a thread into a priority for a user by evaluating their priority_rules in precedence order: content > topic > root fallback. Accepts either a thread_id or raw parameters for pre-insert classification.';

-- apply_priority_rule
CREATE OR REPLACE FUNCTION public.apply_priority_rule (
    p_rule_id uuid,
    p_max_moves int DEFAULT 100
)
    RETURNS TABLE (
        thread_id uuid,
        old_priority_id uuid)
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_rule RECORD;
BEGIN
    SELECT * INTO v_rule FROM public.priority_rule WHERE id = p_rule_id;
    IF NOT FOUND THEN RETURN; END IF;

    RETURN QUERY
    WITH matched AS (
        SELECT tp.thread_id, tp.priority_id AS current_priority_id
        FROM public.thread_priority tp
        JOIN public.thread t ON t.id = tp.thread_id
        WHERE tp.user_id = v_rule.user_id
          AND tp.priority_id IS DISTINCT FROM v_rule.priority_id
          AND t.archived_at IS NULL
          AND t.draft = FALSE
          AND CASE v_rule.type
              WHEN 'content' THEN
                  t.embedding IS NOT NULL
                  AND v_rule.embedding IS NOT NULL
                  AND (1 - (t.embedding <=> v_rule.embedding)) >= 0.7
              WHEN 'topic' THEN
                  v_rule.topic IS NOT NULL
                  AND t.topic = v_rule.topic
          END
        LIMIT p_max_moves
    ),
    filtered AS (
        SELECT m.thread_id, m.current_priority_id
        FROM matched m
        WHERE public.classify_thread_for_user(
            v_rule.user_id,
            m.thread_id
        ) IS NOT DISTINCT FROM v_rule.priority_id
    ),
    moved AS (
        UPDATE public.thread_priority tp
        SET priority_id = v_rule.priority_id
        FROM filtered f
        WHERE tp.thread_id = f.thread_id
          AND tp.user_id = v_rule.user_id
        RETURNING tp.thread_id, f.current_priority_id AS old_priority_id
    )
    SELECT moved.thread_id, moved.old_priority_id FROM moved;
END;
$function$;

COMMENT ON FUNCTION public.apply_priority_rule IS 'Retroactively apply a priority_rule to existing threads. Only moves threads where the rule is the highest-precedence match, capped at p_max_moves.';

-- sync_user_for_group + triggers
CREATE OR REPLACE FUNCTION public.sync_user_for_group ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_max_updated_at timestamptz;
    v_user_id uuid;
BEGIN
    SELECT MAX(updated_at) INTO v_max_updated_at FROM new_table;
    FOR v_user_id IN SELECT DISTINCT ug.user_id
        FROM new_table n JOIN "user"."group" ug ON ug.id = n.id
        ORDER BY ug.user_id LOOP
        INSERT INTO user_sync (user_id, entity, last_update_at)
            VALUES (v_user_id, 'group', v_max_updated_at)
        ON CONFLICT (user_id, entity) DO UPDATE
            SET last_update_at = GREATEST(user_sync.last_update_at, EXCLUDED.last_update_at);
    END LOOP;
    RETURN NULL;
END;
$function$;

-- Publisher group auto-maintenance
CREATE OR REPLACE FUNCTION public.auto_maintain_publisher_group ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_group_id uuid;
    v_contact_id uuid;
BEGIN
    SELECT id INTO v_group_id FROM "group" WHERE auto_publisher_id = COALESCE(NEW.id, OLD.id);
    IF v_group_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO "group" (name, type, auto_publisher_id, created_by, auto_maintained)
        VALUES (NEW.name || ' Publisher', 'private', NEW.id, NEW.created_by, TRUE)
        RETURNING id INTO v_group_id;
    END IF;

    IF v_group_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.created_by IS DISTINCT FROM OLD.created_by) THEN
        SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.created_by AND "primary" = TRUE AND linked = TRUE AND archived_at IS NULL;
        IF v_contact_id IS NOT NULL THEN
            INSERT INTO group_member (group_id, contact_id) VALUES (v_group_id, v_contact_id) ON CONFLICT DO NOTHING;
        END IF;
        INSERT INTO group_admin (group_id, user_id) VALUES (v_group_id, NEW.created_by) ON CONFLICT DO NOTHING;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE FUNCTION public.auto_rename_publisher_group ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE "group"
    SET name = NEW.name || ' Publisher'
    WHERE auto_publisher_id = NEW.id
      AND auto_maintained = TRUE;
    RETURN NEW;
END;
$$;

-- Team group auto-maintenance
CREATE OR REPLACE FUNCTION public.auto_create_team_group ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_group_id uuid;
    v_first_admin_id uuid;
BEGIN
    SELECT tu.user_id INTO v_first_admin_id
    FROM team_user tu
    WHERE tu.team_id = NEW.id
    ORDER BY (tu.role = 'admin') DESC, tu.created_at ASC
    LIMIT 1;

    IF v_first_admin_id IS NULL THEN
        RETURN NEW;
    END IF;

    INSERT INTO "group" (name, type, team_id, created_by, auto_maintained)
    VALUES (NEW.name || ' Team', 'team', NEW.id, v_first_admin_id, TRUE)
    ON CONFLICT DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.auto_maintain_team_group_members ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_group_id uuid;
    v_contact_id uuid;
    v_team_id bigint;
    v_user_id uuid;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_team_id := OLD.team_id;
        v_user_id := OLD.user_id;
    ELSE
        v_team_id := NEW.team_id;
        v_user_id := NEW.user_id;
    END IF;

    SELECT id INTO v_group_id
    FROM "group"
    WHERE team_id = v_team_id AND auto_maintained = TRUE AND auto_team_admin_team_id IS NULL;

    IF v_group_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO "group" (name, type, team_id, created_by, auto_maintained)
        SELECT t.name || ' Team', 'team', t.id, v_user_id, TRUE
        FROM team t WHERE t.id = v_team_id
        ON CONFLICT DO NOTHING
        RETURNING id INTO v_group_id;

        IF v_group_id IS NULL THEN
            SELECT id INTO v_group_id
            FROM "group"
            WHERE team_id = v_team_id AND auto_maintained = TRUE AND auto_team_admin_team_id IS NULL;
        END IF;
    END IF;

    IF v_group_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    SELECT uc.contact_id INTO v_contact_id
    FROM user_contact uc
    WHERE uc.user_id = v_user_id
      AND uc."primary" = TRUE
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;

    IF TG_OP = 'INSERT' THEN
        IF v_contact_id IS NOT NULL THEN
            INSERT INTO group_member (group_id, contact_id)
            VALUES (v_group_id, v_contact_id)
            ON CONFLICT DO NOTHING;
        END IF;
        IF NEW.role = 'admin' THEN
            INSERT INTO group_admin (group_id, user_id)
            VALUES (v_group_id, v_user_id)
            ON CONFLICT DO NOTHING;
        END IF;
    ELSIF TG_OP = 'DELETE' THEN
        IF v_contact_id IS NOT NULL THEN
            DELETE FROM group_member
            WHERE group_id = v_group_id AND contact_id = v_contact_id;
        END IF;
        DELETE FROM group_admin
        WHERE group_id = v_group_id AND user_id = v_user_id;
    ELSIF TG_OP = 'UPDATE' THEN
        IF NEW.role = 'admin' AND OLD.role != 'admin' THEN
            INSERT INTO group_admin (group_id, user_id)
            VALUES (v_group_id, v_user_id)
            ON CONFLICT DO NOTHING;
        ELSIF NEW.role != 'admin' AND OLD.role = 'admin' THEN
            DELETE FROM group_admin
            WHERE group_id = v_group_id AND user_id = v_user_id;
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE FUNCTION public.auto_maintain_team_admin_group ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_group_id uuid;
    v_contact_id uuid;
BEGIN
    IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') AND NEW.role != 'admin' THEN
        SELECT id INTO v_group_id FROM "group" WHERE auto_team_admin_team_id = NEW.team_id;
        IF v_group_id IS NOT NULL THEN
            SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = NEW.user_id AND "primary" = TRUE;
            IF v_contact_id IS NOT NULL THEN
                DELETE FROM group_member WHERE group_id = v_group_id AND contact_id = v_contact_id;
            END IF;
            DELETE FROM group_admin WHERE group_id = v_group_id AND user_id = NEW.user_id;
        END IF;
        RETURN NEW;
    END IF;

    SELECT id INTO v_group_id FROM "group" WHERE auto_team_admin_team_id = COALESCE(NEW.team_id, OLD.team_id);
    IF v_group_id IS NULL AND TG_OP != 'DELETE' THEN
        INSERT INTO "group" (name, type, team_id, auto_team_admin_team_id, created_by, auto_maintained)
        SELECT t.name || ' Admins', 'team', t.id, t.id, NEW.user_id, TRUE
        FROM team t WHERE t.id = NEW.team_id
        RETURNING id INTO v_group_id;
    END IF;

    IF v_group_id IS NULL THEN
        RETURN COALESCE(NEW, OLD);
    END IF;

    SELECT contact_id INTO v_contact_id FROM user_contact WHERE user_id = COALESCE(NEW.user_id, OLD.user_id) AND "primary" = TRUE;

    IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND NEW.role = 'admin') THEN
        IF v_contact_id IS NOT NULL THEN
            INSERT INTO group_member (group_id, contact_id) VALUES (v_group_id, v_contact_id) ON CONFLICT DO NOTHING;
        END IF;
        INSERT INTO group_admin (group_id, user_id) VALUES (v_group_id, COALESCE(NEW.user_id, OLD.user_id)) ON CONFLICT DO NOTHING;
    ELSIF TG_OP = 'DELETE' THEN
        IF v_contact_id IS NOT NULL THEN
            DELETE FROM group_member WHERE group_id = v_group_id AND contact_id = v_contact_id;
        END IF;
        DELETE FROM group_admin WHERE group_id = v_group_id AND user_id = OLD.user_id;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE OR REPLACE FUNCTION public.auto_maintain_everyone_group ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_everyone_group_id uuid;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.linked = TRUE AND NEW."primary" = TRUE THEN
        SELECT id INTO v_everyone_group_id
        FROM "group"
        WHERE auto_maintained = TRUE AND team_id IS NULL AND auto_publisher_id IS NULL;

        IF v_everyone_group_id IS NOT NULL THEN
            INSERT INTO group_member (group_id, contact_id)
            VALUES (v_everyone_group_id, NEW.contact_id)
            ON CONFLICT DO NOTHING;
        END IF;

    ELSIF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND (
        NEW.linked = FALSE OR NEW."primary" = FALSE OR NEW.archived_at IS NOT NULL
    )) THEN
        SELECT id INTO v_everyone_group_id
        FROM "group"
        WHERE auto_maintained = TRUE AND team_id IS NULL AND auto_publisher_id IS NULL;

        IF v_everyone_group_id IS NOT NULL THEN
            DELETE FROM group_member
            WHERE group_id = v_everyone_group_id
              AND contact_id = COALESCE(OLD.contact_id, NEW.contact_id);
        END IF;
    END IF;

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Thread-priority filing based on group membership.
CREATE OR REPLACE FUNCTION public.file_thread_priority_for_group_members ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    r RECORD;
    v_peer_priority_id uuid;
    v_author_user_id uuid;
BEGIN
    IF NEW.groups IS NULL OR cardinality(NEW.groups) = 0 THEN
        RETURN NEW;
    END IF;

    IF EXISTS (SELECT 1 FROM "public"."user" WHERE id = NEW.created_by) THEN
        v_author_user_id := NEW.created_by;
    ELSE
        SELECT pt.owner_id INTO v_author_user_id
        FROM public.twist_instance pt
        WHERE pt.id = NEW.created_by;
    END IF;

    FOR r IN
        SELECT DISTINCT uc.user_id AS peer_user_id
        FROM unnest(NEW.groups) AS arr(group_id)
        JOIN public.group_member gm ON gm.group_id = arr.group_id
        JOIN public.user_contact uc
          ON uc.contact_id = gm.contact_id
         AND uc.linked = TRUE
         AND uc.archived_at IS NULL
        WHERE uc.user_id IS DISTINCT FROM v_author_user_id
    LOOP
        v_peer_priority_id := public.classify_thread_for_user(r.peer_user_id, NEW.id);
        IF v_peer_priority_id IS NOT NULL THEN
            INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (NEW.id, r.peer_user_id, v_peer_priority_id)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

            INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
            VALUES (r.peer_user_id, NEW.id, 'inform-updates', 50)
            ON CONFLICT (user_id, thread_id) DO NOTHING;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.file_thread_priority_on_group_member_change ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    r_thread RECORD;
    v_peer_user_id uuid;
    v_peer_priority_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = NEW.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        LIMIT 1;

        IF v_peer_user_id IS NULL THEN
            RETURN NEW;
        END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id
            FROM public.thread t
            WHERE NEW.group_id = ANY(t.groups)
              AND t.archived_at IS NULL
        LOOP
            v_peer_priority_id := public.classify_thread_for_user(v_peer_user_id, r_thread.thread_id);
            IF v_peer_priority_id IS NULL THEN CONTINUE; END IF;

            INSERT INTO thread_priority (thread_id, user_id, priority_id)
            VALUES (r_thread.thread_id, v_peer_user_id, v_peer_priority_id)
            ON CONFLICT ON CONSTRAINT thread_priority_pkey DO NOTHING;

            INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
            VALUES (v_peer_user_id, r_thread.thread_id, 'inform-updates', 50)
            ON CONFLICT (user_id, thread_id) DO NOTHING;
        END LOOP;

        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        SELECT uc.user_id INTO v_peer_user_id
        FROM public.user_contact uc
        WHERE uc.contact_id = OLD.contact_id
          AND uc.linked = TRUE
          AND uc.archived_at IS NULL
        LIMIT 1;

        IF v_peer_user_id IS NULL THEN RETURN OLD; END IF;

        FOR r_thread IN
            SELECT t.id AS thread_id
            FROM public.thread t
            WHERE OLD.group_id = ANY(t.groups)
              AND t.archived_at IS NULL
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM public.thread t2
                WHERE t2.id = r_thread.thread_id
                  AND (
                    t2.contacts && "user".user_contact_ids(v_peer_user_id)
                    OR EXISTS (
                        SELECT 1 FROM unnest(t2.groups) AS gid
                        JOIN group_member gm2 ON gm2.group_id = gid
                        JOIN user_contact uc2 ON uc2.contact_id = gm2.contact_id
                            AND uc2.linked = TRUE AND uc2.archived_at IS NULL
                        WHERE uc2.user_id = v_peer_user_id
                          AND gm2.group_id != OLD.group_id
                    )
                  )
            ) THEN
                DELETE FROM thread_priority WHERE thread_id = r_thread.thread_id AND user_id = v_peer_user_id;
                DELETE FROM thread_unread WHERE thread_id = r_thread.thread_id AND user_id = v_peer_user_id;
            END IF;
        END LOOP;

        RETURN OLD;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Recreate triggers on the renamed tables.
-- ---------------------------------------------------------------------------

CREATE TRIGGER user_sync_group_insert
    AFTER INSERT ON "group"
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION sync_user_for_group();

CREATE TRIGGER user_sync_group_update
    AFTER UPDATE ON "group"
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
    EXECUTE FUNCTION sync_user_for_group();

CREATE TRIGGER auto_create_team_group
    AFTER INSERT ON team
    FOR EACH ROW
    EXECUTE FUNCTION auto_create_team_group();

CREATE TRIGGER auto_maintain_team_group_members
    AFTER INSERT OR DELETE OR UPDATE ON team_user
    FOR EACH ROW
    EXECUTE FUNCTION auto_maintain_team_group_members();

CREATE TRIGGER auto_maintain_team_admin_group
    AFTER INSERT OR DELETE OR UPDATE OF role ON team_user
    FOR EACH ROW
    EXECUTE FUNCTION auto_maintain_team_admin_group();

CREATE TRIGGER auto_maintain_publisher_group
    AFTER INSERT OR DELETE OR UPDATE OF created_by ON publisher
    FOR EACH ROW
    EXECUTE FUNCTION auto_maintain_publisher_group();

CREATE TRIGGER auto_rename_publisher_group
    AFTER UPDATE OF name ON publisher
    FOR EACH ROW
    WHEN (OLD.name IS DISTINCT FROM NEW.name)
    EXECUTE FUNCTION auto_rename_publisher_group();

CREATE TRIGGER auto_maintain_everyone_group
    AFTER INSERT OR UPDATE OR DELETE ON user_contact
    FOR EACH ROW
    EXECUTE FUNCTION auto_maintain_everyone_group();

CREATE TRIGGER file_thread_priority_for_group_members
    AFTER INSERT OR UPDATE OF groups
    ON thread
    FOR EACH ROW
    EXECUTE FUNCTION file_thread_priority_for_group_members();

CREATE TRIGGER file_thread_priority_on_group_member_change
    AFTER INSERT OR DELETE ON group_member
    FOR EACH ROW
    EXECUTE FUNCTION file_thread_priority_on_group_member_change();

-- ---------------------------------------------------------------------------
-- Recreate user.group view + user.thread + user.note + friends.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW "user"."group"
AS
SELECT
    u.id AS user_id,
    g.id,
    g.created_at,
    g.updated_at,
    g.archived_at,
    g.name,
    g.type,
    g.join_policy,
    g.team_id,
    g.auto_maintained,
    EXISTS (
        SELECT 1 FROM group_admin ga
        WHERE ga.group_id = g.id AND ga.user_id = u.id
    ) AS is_admin,
    EXISTS (
        SELECT 1 FROM group_member gm
        JOIN user_contact uc ON uc.contact_id = gm.contact_id
            AND uc.linked = TRUE AND uc.archived_at IS NULL
        WHERE gm.group_id = g.id AND uc.user_id = u.id
    ) AS is_member,
    CASE
        WHEN EXISTS (
            SELECT 1 FROM group_admin ga
            WHERE ga.group_id = g.id AND ga.user_id = u.id
        ) THEN (
            SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[])
            FROM group_member gm2 WHERE gm2.group_id = g.id
        )
        WHEN g.type IN ('private', 'team') AND EXISTS (
            SELECT 1 FROM group_member gm
            JOIN user_contact uc ON uc.contact_id = gm.contact_id
                AND uc.linked = TRUE AND uc.archived_at IS NULL
            WHERE gm.group_id = g.id AND uc.user_id = u.id
        ) THEN (
            SELECT COALESCE(array_agg(gm2.contact_id), ARRAY[]::uuid[])
            FROM group_member gm2 WHERE gm2.group_id = g.id
        )
        ELSE ARRAY[]::uuid[]
    END AS member_contact_ids
FROM
    public."user" u
    CROSS JOIN "group" g
WHERE
    g.archived_at IS NULL
    AND (
        g.type IN ('public', 'announce')
        OR (g.type = 'team' AND EXISTS (
            SELECT 1 FROM team_user tu
            WHERE tu.team_id = g.team_id AND tu.user_id = u.id
        ))
        OR (g.type = 'private' AND (
            EXISTS (
                SELECT 1 FROM group_admin ga
                WHERE ga.group_id = g.id AND ga.user_id = u.id
            )
            OR EXISTS (
                SELECT 1 FROM group_member gm
                JOIN user_contact uc ON uc.contact_id = gm.contact_id
                    AND uc.linked = TRUE AND uc.archived_at IS NULL
                WHERE gm.group_id = g.id AND uc.user_id = u.id
            )
        ))
    );

ALTER VIEW "user"."group" OWNER TO postgres;

-- ---------------------------------------------------------------------------
-- Recreate user.thread, user.thread_tags, user.note, user.note_redacted,
-- user.note_tags (they were dropped earlier because they referenced
-- thread.topics / user_topic_ids / user.topic).
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW "user"."thread" AS
WITH link_agg AS (
    SELECT thread_id, MAX(source_created_at) AS source_created_at
    FROM link
    GROUP BY thread_id
)
SELECT
    tp.user_id,
    a.id,
    a.created_at,
    GREATEST (a.updated_at, COALESCE(a.last_note_created_at, 'epoch'::timestamptz),
        COALESCE(tu.updated_at, 'epoch'::timestamptz)) AS updated_at,
    a.updated_by,
    COALESCE(a.archived_at, tp.archived_at, upe.archived_at) AS archived_at,
    tp.priority_id,
    upe.path AS priority_path,
    a.draft,
    a.contacts,
    a.groups,
    a.topic,
    a.title,
    a.preview,
    a.icon,
    a.embedding IS NOT NULL AS has_embedding,
    a.last_note_created_at,
    a.last_note_source_created_at,
    tu.bumped_at,
    COALESCE(tu.read_at IS NULL AND tu.user_id IS NOT NULL, FALSE) AS unread,
    COALESCE(CASE WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.importance END, 0::smallint) AS importance,
    COALESCE(CASE WHEN tu.read_at IS NULL AND tu.user_id IS NOT NULL THEN tu.urgency END, NULL) AS urgency,
    COALESCE(
        GREATEST(
            a.last_note_source_created_at,
            la.source_created_at,
            tu.bumped_at,
            (SELECT CASE
                WHEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamptz) <= now()
                THEN COALESCE(upper(s_feed.at), upper(s_feed."on")::timestamptz)
            END
            FROM schedule s_feed
            WHERE s_feed.thread_id = a.id
                AND s_feed.user_id IS NULL
                AND s_feed.occurrence IS NULL
                AND s_feed.archived_at IS NULL
            LIMIT 1)
        ),
        a.created_at
    ) AS activity_at,
    (SELECT tstzrange(
        lo,
        GREATEST(lo, hi),
        '[]'
    ) FROM (SELECT
        COALESCE(
            LEAST(
                (SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamptz)
                 FROM schedule s_lo WHERE s_lo.thread_id = a.id AND s_lo.user_id IS NULL
                 AND s_lo.archived_at IS NULL
                 ORDER BY COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamptz) ASC NULLS LAST
                 LIMIT 1),
                (SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamptz)
                 FROM schedule s_lo WHERE s_lo.thread_id = a.id AND s_lo.user_id = tp.user_id
                 AND s_lo.archived_at IS NULL
                 ORDER BY COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamptz) ASC NULLS LAST
                 LIMIT 1),
                (SELECT COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamptz)
                 FROM schedule s_lo
                 JOIN link l_lo ON l_lo.id = s_lo.link_id
                 WHERE l_lo.thread_id = a.id AND s_lo.user_id IS NULL
                 AND s_lo.archived_at IS NULL
                 ORDER BY COALESCE(lower(s_lo.at), lower(s_lo."on")::timestamptz) ASC NULLS LAST
                 LIMIT 1)
            ),
            a.created_at
        ) AS lo,
        COALESCE(
            CASE
                WHEN EXISTS (
                    SELECT 1 FROM schedule s_rec
                    WHERE s_rec.thread_id = a.id AND s_rec.archived_at IS NULL
                    AND s_rec.recurrence_rule IS NOT NULL
                ) OR EXISTS (
                    SELECT 1 FROM schedule s_rec
                    JOIN link l_rec ON l_rec.id = s_rec.link_id
                    WHERE l_rec.thread_id = a.id AND s_rec.archived_at IS NULL
                    AND s_rec.recurrence_rule IS NOT NULL
                ) THEN 'infinity'::timestamptz
                WHEN EXISTS (
                    SELECT 1 FROM schedule s_ub
                    WHERE s_ub.thread_id = a.id AND s_ub.archived_at IS NULL
                    AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL)
                    AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamptz) IS NULL
                ) OR EXISTS (
                    SELECT 1 FROM schedule s_ub
                    JOIN link l_ub ON l_ub.id = s_ub.link_id
                    WHERE l_ub.thread_id = a.id AND s_ub.archived_at IS NULL
                    AND (s_ub.at IS NOT NULL OR s_ub."on" IS NOT NULL)
                    AND COALESCE(upper(s_ub.at), upper(s_ub."on")::timestamptz) IS NULL
                ) THEN 'infinity'::timestamptz
                ELSE GREATEST(
                    (SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamptz)
                     FROM schedule s_hi WHERE s_hi.thread_id = a.id AND s_hi.user_id IS NULL
                     AND s_hi.archived_at IS NULL
                     ORDER BY COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamptz) DESC NULLS LAST
                     LIMIT 1),
                    (SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamptz)
                     FROM schedule s_hi WHERE s_hi.thread_id = a.id AND s_hi.user_id = tp.user_id
                     AND s_hi.archived_at IS NULL
                     ORDER BY COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamptz) DESC NULLS LAST
                     LIMIT 1),
                    (SELECT COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamptz)
                     FROM schedule s_hi
                     JOIN link l_hi ON l_hi.id = s_hi.link_id
                     WHERE l_hi.thread_id = a.id AND s_hi.user_id IS NULL
                     AND s_hi.archived_at IS NULL
                     ORDER BY COALESCE(upper(s_hi.at), upper(s_hi."on")::timestamptz) DESC NULLS LAST
                     LIMIT 1)
                )
            END,
            a.created_at
        ) AS hi
    ) bounds) AS agenda_at
FROM
    thread a
    JOIN thread_priority tp ON tp.thread_id = a.id
    LEFT JOIN "user".priority_expanded upe
        ON upe.user_id = tp.user_id AND upe.priority_id = tp.priority_id
    LEFT JOIN thread_unread tu ON tu.user_id = tp.user_id
        AND tu.thread_id = a.id
    LEFT JOIN link_agg la ON la.thread_id = a.id
WHERE
    (a.draft = FALSE OR a.created_by = tp.user_id)
    AND (
        a.contacts && "user".user_contact_ids(tp.user_id)
        OR a.groups && "user".user_group_ids(tp.user_id)
    );

ALTER VIEW "user"."thread" OWNER TO postgres;

CREATE OR REPLACE VIEW "user"."thread_tags" AS
SELECT
    ua.user_id,
    ua.id,
    ua.archived_at,
    tt.occurrence,
    tt.updated_at,
    ua.priority_id,
    ua.priority_path,
    tt.tags
FROM
    "user".thread ua
    JOIN LATERAL (
        SELECT
            sq.occurrence,
            jsonb_object_agg(sq.tag_id, sq.actor_ids) FILTER (WHERE sq.actor_ids IS NOT NULL
                AND jsonb_array_length(sq.actor_ids) > 0) AS tags,
            MAX(sq.updated_at) AS updated_at
        FROM (
            SELECT
                at.occurrence,
                at.tag_id,
                jsonb_agg(at.actor_id) FILTER (WHERE at.archived_at IS NULL) AS actor_ids,
                MAX(COALESCE(at.archived_at, at.updated_at)) AS updated_at
            FROM
                "public"."thread_tag" at
            WHERE
                at.thread_id = ua.id
            GROUP BY
                at.occurrence,
                at.tag_id) sq
        GROUP BY
            sq.occurrence) tt ON true;

ALTER VIEW "user"."thread_tags" OWNER TO postgres;

CREATE OR REPLACE VIEW "user"."note" AS
SELECT
    tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    n.archived_at,
    n.thread_id,
    n.draft,
    n.access_contacts,
    n.content,
    n.actions,
    n.mentions,
    n.re_note_id,
    n.merged_from_thread_id
FROM
    note n
    JOIN thread a ON a.id = n.thread_id
    JOIN thread_priority tp ON tp.thread_id = a.id
WHERE
    (n.draft = FALSE OR n.created_by = tp.user_id)
    AND (n.access_contacts IS NULL
        OR n.created_by = tp.user_id
        OR n.access_contacts && "user".user_contact_ids(tp.user_id))
    AND (a.draft = FALSE OR a.created_by = tp.user_id)
    AND (
        a.contacts && "user".user_contact_ids(tp.user_id)
        OR a.groups && "user".user_group_ids(tp.user_id)
    );

ALTER VIEW "user"."note" OWNER TO postgres;

CREATE OR REPLACE VIEW "user"."note_redacted" AS
SELECT
    tp.user_id,
    n.id,
    n.created_at,
    n.updated_at,
    n.source_created_at,
    n.author_id,
    n.created_by,
    n.updated_by,
    COALESCE(n.archived_at, n.updated_at) AS archived_at,
    n.thread_id,
    n.draft,
    CAST(NULL AS uuid[]) AS access_contacts,
    NULL::text AS content,
    NULL::jsonb AS actions,
    CAST(NULL AS uuid[]) AS mentions,
    n.re_note_id,
    n.merged_from_thread_id
FROM
    note n
    JOIN thread a ON a.id = n.thread_id
    JOIN thread_priority tp ON tp.thread_id = a.id
WHERE
    (n.draft = FALSE OR n.created_by = tp.user_id)
    AND (a.draft = FALSE OR a.created_by = tp.user_id)
    AND (
        a.contacts && "user".user_contact_ids(tp.user_id)
        OR a.groups && "user".user_group_ids(tp.user_id)
    )
    AND (n.access_contacts IS NOT NULL
        AND n.created_by != tp.user_id
        AND NOT (COALESCE(n.access_contacts, ARRAY[]::uuid[]) && "user".user_contact_ids(tp.user_id)));

ALTER VIEW "user"."note_redacted" OWNER TO postgres;

CREATE OR REPLACE VIEW "user"."note_tags" AS
SELECT
    ua.user_id,
    n.id,
    nt.updated_at,
    ua.archived_at,
    ua.priority_id,
    ua.priority_path,
    nt.tags
FROM
    note_tags nt
    JOIN note n ON n.id = nt.note_id
    JOIN "user".thread ua ON ua.id = n.thread_id
WHERE
    (n.draft = FALSE OR n.created_by = ua.user_id)
    AND (n.access_contacts IS NULL
        OR n.created_by = ua.user_id
        OR n.access_contacts && "user".user_contact_ids(ua.user_id));

ALTER VIEW "user"."note_tags" OWNER TO postgres;

-- ---------------------------------------------------------------------------
-- activate_invited_user: migrate to new topic-string priority rules.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.activate_invited_user (
    p_user_id uuid
)
    RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $function$
DECLARE
    v_root_priority_id uuid;
    v_new_path ltree;
BEGIN
    SELECT id INTO v_root_priority_id
    FROM public.priority
    WHERE user_id = p_user_id AND nlevel(path) = 1
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

    -- 1. Everyone group -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, topic)
    SELECT p_user_id, p.id, 'topic', g.id::text
    FROM public.priority p
    CROSS JOIN public."group" g
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND g.auto_maintained = TRUE AND g.team_id IS NULL AND g.auto_publisher_id IS NULL AND g.name = 'Everyone';

    -- 2. User account topic -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, topic)
    SELECT p_user_id, p.id, 'topic', p_user_id::text
    FROM public.priority p
    WHERE p.user_id = p_user_id AND p.key = '@plot.app';

    -- 3. Team admin groups -> Using Plot
    INSERT INTO public.priority_rule (user_id, priority_id, type, topic)
    SELECT p_user_id, p.id, 'topic', g.id::text
    FROM public.priority p
    CROSS JOIN public."group" g
    JOIN public.team_user tu ON tu.team_id = g.auto_team_admin_team_id AND tu.user_id = p_user_id
    WHERE p.user_id = p_user_id AND p.key = '@plot.app'
      AND g.auto_team_admin_team_id IS NOT NULL;

    -- 4. Personal twists topic -> Twist Development
    INSERT INTO public.priority_rule (user_id, priority_id, type, topic)
    SELECT p_user_id, p.id, 'topic', 'personal-twists:' || p_user_id::text
    FROM public.priority p
    WHERE p.user_id = p_user_id AND p.key = '@plot.twist-dev';

    -- 5. Publisher groups (where this user is a member) -> Twist Development
    INSERT INTO public.priority_rule (user_id, priority_id, type, topic)
    SELECT p_user_id, p.id, 'topic', g.id::text
    FROM public.priority p
    CROSS JOIN public."group" g
    JOIN public.group_member gm ON gm.group_id = g.id
    JOIN public.user_contact uc ON uc.contact_id = gm.contact_id
    WHERE p.user_id = p_user_id AND p.key = '@plot.twist-dev'
      AND g.auto_publisher_id IS NOT NULL
      AND g.auto_maintained = TRUE
      AND uc.user_id = p_user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;

    RETURN jsonb_build_object('activated', TRUE, 'already_active', FALSE, 'root_priority_id', v_root_priority_id);
END;
$function$;

-- ---------------------------------------------------------------------------
-- get_accessible_twists / is_accessible_twist: use renamed group tables.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_accessible_twists (p_user_id uuid)
    RETURNS SETOF twist
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT DISTINCT twist.*
    FROM twist
    WHERE
        twist.archived_at IS NULL
        AND (
            twist.environment = 'public'
            OR (twist.environment = 'personal' AND twist.user_id = p_user_id)
            OR (twist.environment = 'review' AND EXISTS (SELECT 1 FROM twist_reviewer WHERE user_id = p_user_id))
            OR (twist.publisher_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM "group" g
                JOIN group_member gm ON gm.group_id = g.id
                JOIN user_contact uc ON uc.contact_id = gm.contact_id
                WHERE g.auto_publisher_id = twist.publisher_id
                  AND g.auto_maintained = TRUE
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
              OR (twist.environment = 'review' AND EXISTS (SELECT 1 FROM twist_reviewer WHERE user_id = p_user_id))
              OR (twist.publisher_id IS NOT NULL AND EXISTS (
                  SELECT 1 FROM "group" g
                  JOIN group_member gm ON gm.group_id = g.id
                  JOIN user_contact uc ON uc.contact_id = gm.contact_id
                  WHERE g.auto_publisher_id = twist.publisher_id
                    AND g.auto_maintained = TRUE
                    AND uc.user_id = p_user_id
                    AND uc.linked = TRUE
                    AND uc.archived_at IS NULL
              ))
          )
    )
$function$;

-- ---------------------------------------------------------------------------
-- user.upsert_thread: read/write thread.groups + thread.topic.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION "user".upsert_thread (user_id uuid, p_thread jsonb, p_defaults jsonb DEFAULT '{}' ::jsonb)
    RETURNS thread
    LANGUAGE plpgsql
    AS $function$
DECLARE
    v_result thread;
    v_existing thread;
    v_id uuid;
    v_priority_id uuid;
    v_created_by uuid;
    v_twist_id bigint;
    v_is_archived boolean;
    v_user_contacts uuid[];
    v_user_primary_contact uuid;
    v_input_contacts uuid[];
    v_merged_contacts uuid[];
    v_promoted_contacts uuid[];
    v_input_groups uuid[];
    v_input_topic text;
    v_resolved_topic text;
    v_caller_attested boolean;
BEGIN
    v_id := COALESCE((p_thread ->> 'id')::uuid, (p_defaults ->> 'id')::uuid);
    v_priority_id := COALESCE((p_thread ->> 'priority_id')::uuid, (p_defaults ->> 'priority_id')::uuid);
    v_created_by := COALESCE((p_thread ->> 'created_by')::uuid, (p_defaults ->> 'created_by')::uuid, user_id);

    SELECT COALESCE(array_agg(uc.contact_id), ARRAY[]::uuid[])
    INTO v_user_contacts
    FROM user_contact uc
    WHERE uc.user_id = upsert_thread.user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL;

    SELECT uc.contact_id
    INTO v_user_primary_contact
    FROM user_contact uc
    WHERE uc.user_id = upsert_thread.user_id
      AND uc.linked = TRUE
      AND uc.archived_at IS NULL
    ORDER BY uc.primary DESC NULLS LAST, uc.created_at ASC
    LIMIT 1;

    IF v_created_by IS NOT NULL AND v_created_by IS DISTINCT FROM user_id THEN
        SELECT ti.twist_id INTO v_twist_id
        FROM twist_instance ti
        WHERE ti.id = v_created_by;
    END IF;

    IF v_id IS NULL THEN
        IF (p_thread ? 'key')
            AND v_twist_id IS NOT NULL
            AND (p_thread ->> 'key') IS NOT NULL THEN
            SELECT t.id INTO v_id
            FROM thread t
            WHERE t.twist_id = v_twist_id
              AND t.key = (p_thread ->> 'key')
              AND t.archived_at IS NULL;
        END IF;
        IF v_id IS NULL THEN
            v_id := uuidv7 ();
        END IF;
    END IF;

    IF v_priority_id IS NULL THEN
        SELECT tp.priority_id INTO v_priority_id
        FROM thread_priority tp
        WHERE tp.thread_id = v_id
          AND tp.user_id = upsert_thread.user_id;
    END IF;

    IF v_priority_id IS NULL THEN
        RAISE EXCEPTION 'priority_id must be provided';
    END IF;

    IF NOT user_has_priority_access(upsert_thread.user_id, v_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;

    IF v_created_by IS DISTINCT FROM user_id THEN
        IF NOT EXISTS (
            SELECT 1
            FROM twist_instance pt
            WHERE pt.id = v_created_by
              AND pt.owner_id = upsert_thread.user_id
        ) THEN
            RAISE EXCEPTION 'created_by must be user or owned twist_instance';
        END IF;
    END IF;

    SELECT * INTO v_existing FROM thread WHERE id = v_id;

    v_is_archived := COALESCE(
        v_existing.archived_at IS NOT NULL
        OR (v_existing.id IS NOT NULL AND NOT EXISTS (
            SELECT 1
            FROM thread_priority tp
            WHERE tp.thread_id = v_existing.id
              AND tp.user_id = upsert_thread.user_id
              AND tp.archived_at IS NULL
              AND EXISTS (
                  SELECT 1 FROM priority p
                  WHERE p.id = tp.priority_id
                    AND p.archived_at IS NULL
              )
        )),
        FALSE
    );

    v_input_contacts := CASE
        WHEN p_thread ? 'contacts' AND jsonb_typeof(p_thread -> 'contacts') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'contacts') elem), ARRAY[]::uuid[])
        WHEN p_defaults ? 'contacts' AND jsonb_typeof(p_defaults -> 'contacts') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'contacts') elem), ARRAY[]::uuid[])
        ELSE ARRAY[]::uuid[]
    END;

    v_input_groups := CASE
        WHEN p_thread ? 'groups' AND jsonb_typeof(p_thread -> 'groups') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_thread -> 'groups') elem), ARRAY[]::uuid[])
        WHEN p_defaults ? 'groups' AND jsonb_typeof(p_defaults -> 'groups') = 'array' THEN
            COALESCE((SELECT array_agg(elem::uuid) FROM jsonb_array_elements_text(p_defaults -> 'groups') elem), ARRAY[]::uuid[])
        ELSE COALESCE(v_existing.groups, ARRAY[]::uuid[])
    END;

    v_input_topic := COALESCE(p_thread ->> 'topic', p_defaults ->> 'topic');

    IF v_existing.id IS NULL AND v_input_topic IS NULL THEN
        IF cardinality(v_input_groups) > 0 THEN
            v_resolved_topic := v_input_groups[1]::text;
        END IF;
    ELSE
        v_resolved_topic := v_input_topic;
    END IF;

    v_caller_attested := (v_existing.id IS NULL)
        OR (v_created_by = upsert_thread.user_id AND v_twist_id IS NULL)
        OR (v_user_contacts && COALESCE(v_existing.contacts, ARRAY[]::uuid[]));

    IF v_caller_attested THEN
        SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
        INTO v_merged_contacts
        FROM unnest(
            COALESCE(v_existing.contacts, ARRAY[]::uuid[])
            || v_input_contacts
            || v_user_contacts
        ) AS x;
    ELSE
        v_merged_contacts := COALESCE(v_existing.contacts, ARRAY[]::uuid[]);
    END IF;

    IF v_caller_attested
       AND v_existing.pending_contacts IS NOT NULL
       AND cardinality(v_existing.pending_contacts) > 0 THEN
        SELECT COALESCE(array_agg(DISTINCT p), ARRAY[]::uuid[])
        INTO v_promoted_contacts
        FROM unnest(v_existing.pending_contacts) AS p
        WHERE p = ANY(v_input_contacts);
        IF cardinality(v_promoted_contacts) > 0 THEN
            SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
            INTO v_merged_contacts
            FROM unnest(v_merged_contacts || v_promoted_contacts) AS x;
        END IF;
    ELSE
        v_promoted_contacts := ARRAY[]::uuid[];
    END IF;

    INSERT INTO thread (
        id, created_by, title, preview, updated_by, sync_depth, contacts, groups, topic,
        draft, key, icon, twist_id, pending_contacts
    )
    VALUES (
        v_id,
        v_created_by,
        COALESCE(p_thread ->> 'title', p_defaults ->> 'title', v_existing.title),
        COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', v_existing.preview),
        COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, v_existing.updated_by, 0),
        COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, v_existing.sync_depth),
        v_merged_contacts,
        v_input_groups,
        v_resolved_topic,
        COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, v_existing.draft, FALSE),
        COALESCE(p_thread ->> 'key', p_defaults ->> 'key', v_existing.key),
        COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', v_existing.icon),
        v_twist_id,
        ARRAY[]::uuid[]
    )
    ON CONFLICT (id)
        DO UPDATE SET
            title = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'title', p_defaults ->> 'title', thread.title)
            ELSE
                CASE WHEN p_thread ? 'title' THEN p_thread ->> 'title' ELSE thread.title END
            END,
            preview = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'preview', p_defaults ->> 'preview', thread.preview)
            ELSE
                CASE WHEN p_thread ? 'preview' THEN p_thread ->> 'preview' ELSE thread.preview END
            END,
            updated_by = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'updated_by')::integer, (p_defaults ->> 'updated_by')::integer, thread.updated_by)
            ELSE
                CASE WHEN p_thread ? 'updated_by' THEN (p_thread ->> 'updated_by')::integer ELSE thread.updated_by END
            END,
            sync_depth = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'sync_depth')::smallint, (p_defaults ->> 'sync_depth')::smallint, thread.sync_depth)
            ELSE
                CASE WHEN p_thread ? 'sync_depth' THEN (p_thread ->> 'sync_depth')::smallint ELSE thread.sync_depth END
            END,
            contacts = v_merged_contacts,
            groups = CASE WHEN v_is_archived THEN
                v_input_groups
            ELSE
                CASE WHEN p_thread ? 'groups' THEN v_input_groups ELSE thread.groups END
            END,
            topic = CASE WHEN v_is_archived THEN
                v_resolved_topic
            ELSE
                CASE WHEN p_thread ? 'topic' THEN v_input_topic ELSE thread.topic END
            END,
            draft = CASE WHEN v_is_archived THEN
                COALESCE((p_thread ->> 'draft')::boolean, (p_defaults ->> 'draft')::boolean, thread.draft)
            ELSE
                CASE WHEN p_thread ? 'draft' THEN (p_thread ->> 'draft')::boolean ELSE thread.draft END
            END,
            icon = CASE WHEN v_is_archived THEN
                COALESCE(p_thread ->> 'icon', p_defaults ->> 'icon', thread.icon)
            ELSE
                CASE WHEN p_thread ? 'icon' THEN p_thread ->> 'icon' ELSE thread.icon END
            END,
            archived_at = CASE WHEN v_is_archived THEN
                CASE WHEN p_thread ? 'archived_at' THEN (p_thread ->> 'archived_at')::timestamptz
                     WHEN p_defaults ? 'archived_at' THEN (p_defaults ->> 'archived_at')::timestamptz
                     ELSE thread.archived_at END
            ELSE
                CASE WHEN p_thread ? 'archived_at' THEN (p_thread ->> 'archived_at')::timestamptz ELSE thread.archived_at END
            END,
            pending_contacts = CASE
                WHEN cardinality(v_promoted_contacts) > 0 THEN
                    COALESCE((
                        SELECT array_agg(p)
                        FROM unnest(thread.pending_contacts) AS p
                        WHERE NOT (p = ANY(v_promoted_contacts))
                    ), ARRAY[]::uuid[])
                ELSE thread.pending_contacts
            END
        RETURNING * INTO v_result;

    IF v_caller_attested THEN
        INSERT INTO thread_priority (thread_id, user_id, priority_id)
        VALUES (v_result.id, upsert_thread.user_id, v_priority_id)
        ON CONFLICT ON CONSTRAINT thread_priority_pkey
        DO UPDATE SET
            priority_id = CASE
                WHEN p_thread ? 'priority_id' THEN EXCLUDED.priority_id
                WHEN v_is_archived THEN EXCLUDED.priority_id
                ELSE thread_priority.priority_id
            END,
            archived_at = NULL,
            updated_at = now();
    ELSE
        IF v_user_primary_contact IS NOT NULL THEN
            UPDATE thread
            SET pending_contacts = (
                SELECT COALESCE(array_agg(DISTINCT x), ARRAY[]::uuid[])
                FROM unnest(COALESCE(pending_contacts, ARRAY[]::uuid[]) || ARRAY[v_user_primary_contact]) AS x
            )
            WHERE id = v_result.id
              AND NOT (v_user_primary_contact = ANY(COALESCE(pending_contacts, ARRAY[]::uuid[])))
              AND NOT (v_user_primary_contact = ANY(COALESCE(contacts, ARRAY[]::uuid[])));
            SELECT * INTO v_result FROM thread WHERE id = v_result.id;
        END IF;
    END IF;

    IF cardinality(v_promoted_contacts) > 0 THEN
        DECLARE
            r RECORD;
            v_peer_priority uuid;
        BEGIN
            FOR r IN
                SELECT DISTINCT uc.user_id AS peer_user_id
                FROM unnest(v_promoted_contacts) AS arr(contact_id)
                JOIN user_contact uc
                  ON uc.contact_id = arr.contact_id
                 AND uc.linked = TRUE
                 AND uc.archived_at IS NULL
                WHERE uc.user_id IS DISTINCT FROM upsert_thread.user_id
            LOOP
                v_peer_priority := public.classify_thread_for_user(r.peer_user_id, v_result.id);
                IF v_peer_priority IS NOT NULL THEN
                    INSERT INTO thread_priority (thread_id, user_id, priority_id)
                    VALUES (v_result.id, r.peer_user_id, v_peer_priority)
                    ON CONFLICT ON CONSTRAINT thread_priority_pkey
                    DO UPDATE SET archived_at = NULL, updated_at = now();

                    INSERT INTO thread_unread (user_id, thread_id, urgency, importance)
                    VALUES (r.peer_user_id, v_result.id, 'inform-updates', 50)
                    ON CONFLICT ON CONSTRAINT thread_unread_pkey DO NOTHING;
                END IF;
            END LOOP;
        END;
    END IF;

    IF v_result.contacts IS NOT NULL AND cardinality(v_result.contacts) > 0 THEN
        INSERT INTO user_contact (user_id, contact_id, linked, source)
        SELECT upsert_thread.user_id, arr.contact_id, false, 'thread'
        FROM unnest(v_result.contacts) AS arr(contact_id)
        WHERE EXISTS (SELECT 1 FROM contact c WHERE c.id = arr.contact_id)
        ON CONFLICT ON CONSTRAINT user_contact_pkey DO NOTHING;
    END IF;

    RETURN v_result;
END;
$function$;
