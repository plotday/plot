-- =====================================================================
-- Rename organization → team.
-- Uses ALTER ... RENAME wherever possible so existing data, indexes, FKs,
-- and dependent views survive the rename instead of being dropped/recreated.
-- =====================================================================

-- 1. Rename the enum type first (referenced by tables below).
ALTER TYPE "public"."organization_role" RENAME TO "team_role";

-- 2. Rename tables in dependency order. Dependent objects
--    (FKs, indexes, triggers) follow automatically with their old names
--    and are renamed explicitly in step 5.
ALTER TABLE "public"."organization" RENAME TO "team";
ALTER TABLE "public"."organization_member" RENAME TO "team_user";
ALTER TABLE "public"."organization_subscription" RENAME TO "team_subscription";
ALTER TABLE "public"."organization_invitation" RENAME TO "team_invitation";

-- 3. Rename organization_id → team_id columns. RENAME COLUMN preserves any
--    views that reference these columns (unlike DROP/ADD).
ALTER TABLE "public"."priority" RENAME COLUMN "organization_id" TO "team_id";
ALTER TABLE "public"."ai_key" RENAME COLUMN "organization_id" TO "team_id";
ALTER TABLE "public"."ai_preference" RENAME COLUMN "organization_id" TO "team_id";
ALTER TABLE "public"."domain" RENAME COLUMN "organization_id" TO "team_id";
ALTER TABLE "public"."team_user" RENAME COLUMN "organization_id" TO "team_id";
ALTER TABLE "public"."team_subscription" RENAME COLUMN "organization_id" TO "team_id";
ALTER TABLE "public"."team_invitation" RENAME COLUMN "organization_id" TO "team_id";

-- 4. Rename check constraints that hard-code the old names.
ALTER TABLE "public"."ai_key" RENAME CONSTRAINT "ai_key_scope_check" TO "ai_key_scope_check_old";
ALTER TABLE "public"."ai_key" DROP CONSTRAINT "ai_key_scope_check_old";
ALTER TABLE "public"."ai_key" ADD CONSTRAINT "ai_key_scope_check" CHECK (
    ((user_id IS NOT NULL) AND (team_id IS NULL))
    OR ((user_id IS NULL) AND (team_id IS NOT NULL))
);
ALTER TABLE "public"."ai_preference" RENAME CONSTRAINT "ai_preference_scope_check" TO "ai_preference_scope_check_old";
ALTER TABLE "public"."ai_preference" DROP CONSTRAINT "ai_preference_scope_check_old";
ALTER TABLE "public"."ai_preference" ADD CONSTRAINT "ai_preference_scope_check" CHECK (
    ((user_id IS NOT NULL) AND (team_id IS NULL))
    OR ((user_id IS NULL) AND (team_id IS NOT NULL))
);

-- 5. Rename foreign-key and unique constraints that carry the old table/column
--    names.
ALTER TABLE "public"."priority" RENAME CONSTRAINT "priority_organization_id_fkey" TO "priority_team_id_fkey";
ALTER TABLE "public"."ai_key" RENAME CONSTRAINT "ai_key_organization_id_fkey" TO "ai_key_team_id_fkey";
ALTER TABLE "public"."ai_preference" RENAME CONSTRAINT "ai_preference_organization_id_fkey" TO "ai_preference_team_id_fkey";
ALTER TABLE "public"."domain" RENAME CONSTRAINT "domain_organization_id_fkey" TO "domain_team_id_fkey";
ALTER TABLE "public"."team_user" RENAME CONSTRAINT "organization_member_organization_id_fkey" TO "team_user_team_id_fkey";
ALTER TABLE "public"."team_user" RENAME CONSTRAINT "organization_member_user_id_fkey" TO "team_user_user_id_fkey";
ALTER TABLE "public"."team_user" RENAME CONSTRAINT "organization_member_organization_id_user_id_key" TO "team_user_team_id_user_id_key";
ALTER TABLE "public"."team_subscription" RENAME CONSTRAINT "organization_subscription_organization_id_fkey" TO "team_subscription_team_id_fkey";
ALTER TABLE "public"."team_subscription" RENAME CONSTRAINT "organization_subscription_organization_id_key" TO "team_subscription_team_id_key";
ALTER TABLE "public"."team_subscription" RENAME CONSTRAINT "organization_subscription_stripe_customer_id_key" TO "team_subscription_stripe_customer_id_key";
ALTER TABLE "public"."team_subscription" RENAME CONSTRAINT "organization_subscription_stripe_subscription_id_key" TO "team_subscription_stripe_subscription_id_key";
ALTER TABLE "public"."team_invitation" RENAME CONSTRAINT "organization_invitation_organization_id_fkey" TO "team_invitation_team_id_fkey";
ALTER TABLE "public"."team_invitation" RENAME CONSTRAINT "organization_invitation_invited_by_fkey" TO "team_invitation_invited_by_fkey";
ALTER TABLE "public"."team_invitation" RENAME CONSTRAINT "organization_invitation_email_check" TO "team_invitation_email_check";
ALTER TABLE "public"."team_invitation" RENAME CONSTRAINT "organization_invitation_organization_id_email_key" TO "team_invitation_team_id_email_key";

-- 6. Rename indexes.
ALTER INDEX "public"."idx_organization_member_organization_id" RENAME TO "idx_team_user_team_id";
ALTER INDEX "public"."idx_organization_member_user_id" RENAME TO "idx_team_user_user_id";
ALTER INDEX "public"."idx_organization_subscription_organization_id" RENAME TO "idx_team_subscription_team_id";
ALTER INDEX "public"."idx_organization_subscription_stripe_customer_id" RENAME TO "idx_team_subscription_stripe_customer_id";
ALTER INDEX "public"."idx_organization_subscription_stripe_subscription_id" RENAME TO "idx_team_subscription_stripe_subscription_id";
ALTER INDEX "public"."idx_organization_invitation_email" RENAME TO "idx_team_invitation_email";
ALTER INDEX "public"."idx_ai_key_org_standard" RENAME TO "idx_ai_key_team_standard";
ALTER INDEX "public"."idx_ai_key_org_custom" RENAME TO "idx_ai_key_team_custom";
ALTER INDEX "public"."idx_ai_key_org_id" RENAME TO "idx_ai_key_team_id";
ALTER INDEX "public"."idx_ai_preference_org" RENAME TO "idx_ai_preference_team";

-- 7. Rename triggers.
ALTER TRIGGER "set_organization_updated_at" ON "public"."team" RENAME TO "set_team_updated_at";
ALTER TRIGGER "set_organization_subscription_updated_at" ON "public"."team_subscription" RENAME TO "set_team_subscription_updated_at";
ALTER TRIGGER "set_organization_subscription_created_at" ON "public"."team_subscription" RENAME TO "set_team_subscription_created_at";
-- The propagate_organization_id triggers on priority reference functions that
-- are being renamed below, so drop and recreate them with the new names.
DROP TRIGGER IF EXISTS "priority_propagate_org_id" ON "public"."priority";
DROP TRIGGER IF EXISTS "priority_propagate_org_id_update" ON "public"."priority";

-- The scoped partial indexes in priority_unread.sql were rebuilt against the
-- new team_id column via the schema definitions below; nothing to do here.

-- 8. Now drop the old partial indexes on ai_key that still reference
--    organization-named predicates (they have been recreated with team_id
--    predicates above). Atlas emits CREATE statements below for these.
-- (Nothing to drop here — RENAME INDEX above handles existing partial indexes;
-- Postgres updates the stored predicate when the underlying column is renamed.)

-- =====================================================================
-- Function and view definitions follow. These are idempotent
-- CREATE OR REPLACE statements that redefine the bodies to use team_id.
-- =====================================================================

-- Modify "move_priority" function
CREATE OR REPLACE FUNCTION "public"."move_priority" ("p_priority_id" uuid, "p_new_parent_path" public.ltree) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_old_path ltree;
    v_new_path ltree;
    v_priority_label text;
    v_priority_team_id bigint;
    v_dest_parent_team_id bigint;
    v_new_parent_team_id bigint;
BEGIN
    -- Get the current path of the priority being moved
    SELECT
        path,
        team_id INTO v_old_path,
        v_priority_team_id
    FROM
        public.priority
    WHERE
        id = p_priority_id;
    -- If priority doesn't exist, raise an exception
    IF v_old_path IS NULL THEN
        RAISE EXCEPTION 'Priority with id % not found', p_priority_id;
    END IF;
    -- Prevent moving a priority to be a descendant of itself
    IF p_new_parent_path IS NOT NULL AND (p_new_parent_path <@ v_old_path OR p_new_parent_path = v_old_path) THEN
        RAISE EXCEPTION 'Cannot move priority to be a descendant of itself';
    END IF;
    -- Block moves that cross team boundaries
    IF v_priority_team_id IS NOT NULL THEN
        IF p_new_parent_path IS NULL THEN
            RAISE EXCEPTION 'Cannot move team priority outside its team tree';
        END IF;
        SELECT
            team_id INTO v_dest_parent_team_id
        FROM
            public.priority
        WHERE
            path = p_new_parent_path;
        IF v_dest_parent_team_id IS DISTINCT FROM v_priority_team_id THEN
            RAISE EXCEPTION 'Cannot move team priority outside its team tree';
        END IF;
    END IF;
    -- Extract the last label from the current path (the priority's own identifier)
    v_priority_label := ltree2text (subpath (v_old_path, -1));
    -- Calculate the new path
    IF p_new_parent_path IS NULL THEN
        -- Moving to root level
        v_new_path := text2ltree (v_priority_label);
    ELSE
        -- Moving under a parent
        v_new_path := text2ltree (ltree2text (p_new_parent_path) || '.' || v_priority_label);
    END IF;
    -- Update all priorities whose path starts with the old path
    -- This includes the priority itself and all its descendants
    UPDATE
        public.priority
    SET
        path = CASE
        -- For the priority itself, use the new path directly
        WHEN path = v_old_path THEN
            v_new_path
            -- For descendants, replace the old path prefix with the new path
        ELSE
            text2ltree (ltree2text (v_new_path) || '.' || ltree2text (subpath (path, nlevel (v_old_path))))
        END
    WHERE
        path <@ v_old_path
        OR path = v_old_path;
    -- Propagate team_id to moved priority and descendants (for moves into team tree)
    IF p_new_parent_path IS NOT NULL THEN
        SELECT
            team_id INTO v_new_parent_team_id
        FROM
            public.priority
        WHERE
            path = p_new_parent_path;
        IF v_new_parent_team_id IS NOT NULL THEN
            UPDATE
                public.priority
            SET
                team_id = v_new_parent_team_id
            WHERE
                path <@ v_new_path
                AND (team_id IS DISTINCT FROM v_new_parent_team_id);
        END IF;
    END IF;
END;
$$;
-- Modify "upsert_priority" function
CREATE OR REPLACE FUNCTION "user"."upsert_priority" ("user_id" uuid, "p_priority" jsonb) RETURNS "user"."priority" LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
#variable_conflict use_column
DECLARE
    _input "user"."priority";
    _old "user"."priority";
    v_row "user"."priority";
    _priority_id uuid;
    _is_creator boolean;
    _priority_default_color integer;
    _parent_visual_path ltree;
    _label text;
    _parent_actual_path ltree;
    _actual_path ltree;
    _is_move boolean;
    _is_visual_move boolean := FALSE;
    _user_personal_root_path ltree;
    _old_is_personal boolean;
    _new_is_personal boolean;
    _aliased_root_id uuid;
    _within_aliased_tree boolean;
    _priority_exists boolean;
    _old_actual_path ltree;
    _old_team_id bigint;
    _new_team_id bigint;
BEGIN
    -- Extract input fields from JSONB into the view's row type
    _input := jsonb_populate_record(NULL::"user"."priority", p_priority || jsonb_build_object('user_id', upsert_priority.user_id));
    _is_creator := (_input.created_by = upsert_priority.user_id);
    -- Check if priority already exists (to distinguish INSERT from UPDATE)
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                priority
            WHERE
                id = _input.id) INTO _priority_exists;
    -- Viewer enforcement: viewers cannot create new priorities
    -- For existing priorities, allow through (only priority_settings changes like reordering)
    IF NOT _priority_exists AND nlevel(_input.path) > 1 THEN
        DECLARE
            _parent_priority_id uuid;
            _parent_path ltree;
        BEGIN
            _parent_path := subpath(_input.path, 0, nlevel(_input.path) - 1);
            SELECT up.id INTO _parent_priority_id
            FROM "user".priority up
            WHERE up.user_id = upsert_priority.user_id AND up.path = _parent_path
            LIMIT 1;
            IF _parent_priority_id IS NOT NULL AND "user".get_effective_role(upsert_priority.user_id, _parent_priority_id) = 'viewer' THEN
                RAISE EXCEPTION 'Viewer members cannot create priorities';
            END IF;
        END;
    END IF;
    -- Look up existing row from view if it exists (replaces OLD trigger variable)
    IF _priority_exists THEN
        SELECT
            * INTO _old
        FROM
            "user".priority up
        WHERE
            up.user_id = upsert_priority.user_id
            AND up.id = _input.id;
    END IF;
    -- For existing priorities, compute what the new actual path would be
    -- This is needed for move detection since global_path is a computed column
    IF _priority_exists THEN
        _old_actual_path := _old.global_path;
        IF _old_actual_path IS NULL THEN
            SELECT
                path INTO _old_actual_path
            FROM
                priority
            WHERE
                id = _input.id;
        END IF;
        IF nlevel (_input.path) > 1 THEN
            -- Extract parent path and label from visual path
            _parent_visual_path := subpath (_input.path, 0, nlevel (_input.path) - 1);
            _label := text(subpath (_input.path, nlevel (_input.path) - 1, 1));
            -- Look up parent's ID and actual path from visual path
            SELECT
                global_path INTO _parent_actual_path
            FROM
                "user".priority
            WHERE
                user_id = upsert_priority.user_id
                AND path = _parent_visual_path
            LIMIT 1;
            IF _parent_actual_path IS NULL THEN
                RAISE EXCEPTION 'Parent priority not found'
                    USING HINT = 'parent_visual_path=' || _parent_visual_path::text;
            END IF;
            -- Compute what the new actual path would be
            _actual_path := _parent_actual_path || _label::ltree;
        ELSE
            -- Root level priority (nlevel = 1)
            _actual_path := _input.path;
        END IF;
    END IF;
    -- Detect if this is a move (actual path changed on existing priority)
    _is_move := (_priority_exists
        AND _actual_path IS NOT NULL
        AND _old_actual_path IS DISTINCT FROM _actual_path);
    -- If the visual path hasn't changed, this is not a move.
    -- The visual-to-actual path resolution can produce false positives for shared
    -- root priorities (where visual path includes personal root prefix or alias).
    IF _is_move AND _old IS NOT NULL AND _input.path IS NOT DISTINCT FROM _old.path THEN
        _is_move := FALSE;
        _actual_path := _old_actual_path;
    END IF;
    IF _is_move THEN
        -- Root priorities: visual-only move (per-user alias, no actual path change)
        IF _input.root THEN
            -- Get user's personal root path
            SELECT
                p.path INTO _user_personal_root_path
            FROM
                priority_user pu
                JOIN priority p ON pu.priority_id = p.id
            WHERE
                pu.user_id = upsert_priority.user_id
                AND pu.personal = TRUE
                AND pu.archived_at IS NULL
            LIMIT 1;
            -- Compute default visual path (team root as direct child of personal root)
            DECLARE
                _default_visual_path ltree;
            BEGIN
                _default_visual_path := _user_personal_root_path || subpath(_old_actual_path, 0, 1);
                IF _input.path = _default_visual_path THEN
                    -- Reset to default: remove any existing alias
                    DELETE FROM priority_setting
                    WHERE user_id = upsert_priority.user_id
                        AND priority_id = _input.id
                        AND key = 'path';
                ELSE
                    -- Create/update visual alias
                    INSERT INTO priority_setting (user_id, priority_id, key, value)
                    VALUES (upsert_priority.user_id, _input.id, 'path', to_jsonb(text(_input.path)))
                    ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
                END IF;
            END;
            -- Not an actual move — clear move flags so title/color/order updates still apply
            _is_move := FALSE;
            _actual_path := NULL;
        ELSE
        -- Get user's personal root path (actual path)
        SELECT
            p.path INTO _user_personal_root_path
        FROM
            priority_user pu
            JOIN priority p ON pu.priority_id = p.id
        WHERE
            pu.user_id = upsert_priority.user_id
            AND pu.personal = TRUE
            AND pu.archived_at IS NULL
        LIMIT 1;
        -- Determine if old and new locations are under personal root
        _old_is_personal := (_user_personal_root_path @> _old_actual_path);
        _new_is_personal := (_user_personal_root_path @> _actual_path);
        -- Prevent circular reference
        IF _actual_path <@ _old_actual_path OR _actual_path = _old_actual_path THEN
            RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                USING HINT = 'old_path=' || _old_actual_path::text || ', new_path=' || _actual_path::text;
        END IF;
        -- Check if move is within an aliased tree
        _within_aliased_tree := FALSE;
        _aliased_root_id := NULL;
        IF NOT _old_is_personal AND _new_is_personal THEN
            -- Find deepest ancestor where both old and new paths are under the aliased root
            SELECT
                ps.priority_id INTO _aliased_root_id
            FROM
                priority_setting ps
                JOIN priority p ON ps.priority_id = p.id
            WHERE
                ps.user_id = upsert_priority.user_id
                AND ps.key = 'path'
                AND _input.path <@ (ps.value #>> '{}')::ltree
                AND _old.path <@ (ps.value #>> '{}')::ltree
                AND (ps.value #>> '{}')::ltree != p.path
                AND _old_actual_path <@ p.path
                AND _actual_path <@ p.path
            ORDER BY
                nlevel ((ps.value #>> '{}')::ltree) DESC
            LIMIT 1;
            IF _aliased_root_id IS NOT NULL THEN
                _within_aliased_tree := TRUE;
            END IF;
        END IF;
        -- Determine move type and execute appropriate action
        IF _old_is_personal AND _new_is_personal THEN
            -- Type 1a: Actual move within personal tree
            PERFORM
                move_priority (_input.id, _parent_actual_path);
            _actual_path := NULL;
        ELSIF NOT _old_is_personal AND NOT _new_is_personal THEN
            -- Type 1b: Actual move within/between shared trees
            -- Notify users who lose access if the priority moves to a different shared tree
            PERFORM
                notify_displaced_priority_users (_input.id, _old_actual_path, _parent_actual_path);
            PERFORM
                move_priority (_input.id, _parent_actual_path);
            _actual_path := NULL;
        ELSIF NOT _old_is_personal
                AND _new_is_personal
                AND _within_aliased_tree THEN
                -- Type 3: Actual move within aliased tree (no displacement - same root)
                PERFORM
                    move_priority (_input.id, _parent_actual_path);
            _actual_path := NULL;
        ELSIF NOT _old_is_personal
                AND _new_is_personal THEN
                -- Type 4: Move from shared tree into personal tree
                -- If shared with other users, do a visual-only move to avoid
                -- the priority appearing as personal (path under personal root)
                IF EXISTS (
                    SELECT 1 FROM priority_user
                    WHERE priority_id = _input.id
                    AND user_id != upsert_priority.user_id
                    AND archived_at IS NULL
                ) THEN
                    -- Shared priority: visual-only move (alias under personal tree)
                    INSERT INTO priority_setting (user_id, priority_id, key, value)
                    VALUES (upsert_priority.user_id, _input.id, 'path', to_jsonb(text(_input.path)))
                    ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
                    _is_visual_move := TRUE;
                    _actual_path := NULL;
                ELSE
                    -- Unshared priority: actual move into personal tree
                    PERFORM
                        notify_displaced_priority_users (_input.id, _old_actual_path, _parent_actual_path);
                    PERFORM
                        move_priority (_input.id, _parent_actual_path);
                    _actual_path := NULL;
                    -- Clear any existing visual alias now that priority is in the personal tree
                    DELETE FROM priority_setting
                    WHERE user_id = upsert_priority.user_id AND priority_id = _input.id AND key = 'path';
                END IF;
        ELSIF _old_is_personal
                AND NOT _new_is_personal THEN
                RAISE EXCEPTION 'Cannot move personal priority into shared tree'
                USING HINT = 'Use Share dialog to share a personal priority';
        END IF;
        END IF; -- END root vs non-root branch
    END IF;
    -- Translate visual path to actual path for new sub-priorities
    IF _is_move IS NOT TRUE AND NOT _priority_exists AND nlevel (_input.path) > 1 THEN
        _parent_visual_path := subpath (_input.path, 0, nlevel (_input.path) - 1);
        _label := text(subpath (_input.path, nlevel (_input.path) - 1, 1));
        SELECT
            global_path INTO _parent_actual_path
        FROM
            "user".priority
        WHERE
            user_id = upsert_priority.user_id
            AND path = _parent_visual_path
        LIMIT 1;
        IF _parent_actual_path IS NOT NULL THEN
            _actual_path := _parent_actual_path || _label::ltree;
        ELSE
            _actual_path := _input.path;
        END IF;
    ELSIF _is_move IS NOT TRUE THEN
        _actual_path := _input.path;
    END IF;
    -- Get the priority's default color for initializing new priority_settings
    SELECT
        color INTO _priority_default_color
    FROM
        priority
    WHERE
        id = _input.id;
    -- Update priority table
    IF _actual_path IS NOT NULL THEN
        INSERT INTO priority (id, archived_at, title, color, path, created_by, updated_by, inherit_members, team_id)
            VALUES (_input.id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _actual_path, _input.created_by, _input.updated_by, COALESCE(_input.inherit_members, TRUE),
                CASE WHEN _is_creator THEN _input.team_id ELSE NULL END)
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = _input.archived_at,
                title = _input.title,
                color = CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    priority.color
                END,
                updated_by = _input.updated_by,
                inherit_members = COALESCE(_input.inherit_members, priority.inherit_members),
                team_id = CASE WHEN _is_creator THEN _input.team_id ELSE priority.team_id END
            RETURNING
                id INTO _priority_id;
    ELSE
        -- For moves, just update non-path fields
        UPDATE
            priority
        SET
            archived_at = _input.archived_at,
            title = _input.title,
            color = CASE WHEN _is_creator THEN
                _input.color
            ELSE
                priority.color
            END,
            updated_by = _input.updated_by,
            inherit_members = COALESCE(_input.inherit_members, priority.inherit_members),
            team_id = CASE WHEN _is_creator THEN _input.team_id ELSE priority.team_id END
        WHERE
            id = _input.id
        RETURNING
            id INTO _priority_id;
    END IF;
    -- Handle team_id changes: authorization, promote-to-root, and descendant propagation
    IF _is_creator THEN
        SELECT team_id INTO _old_team_id FROM priority WHERE id = _priority_id;
        _new_team_id := _input.team_id;
        -- Only act when team_id actually changed
        IF _old_team_id IS DISTINCT FROM _new_team_id THEN
            -- Removing from team: require admin role
            IF _old_team_id IS NOT NULL AND (_new_team_id IS NULL OR _new_team_id != _old_team_id) THEN
                IF NOT EXISTS (
                    SELECT 1 FROM team_user
                    WHERE team_id = _old_team_id
                    AND user_id = upsert_priority.user_id
                    AND role = 'admin'
                ) THEN
                    RAISE EXCEPTION 'Only team admins can remove a priority from the team';
                END IF;
            END IF;
            -- Setting team: require membership
            IF _new_team_id IS NOT NULL THEN
                IF NOT EXISTS (
                    SELECT 1 FROM team_user
                    WHERE team_id = _new_team_id
                    AND user_id = upsert_priority.user_id
                ) THEN
                    RAISE EXCEPTION 'Must be a member of the team';
                END IF;
            END IF;
            -- Auto-promote to root: if setting team_id on a non-root priority, move it to root level
            IF _new_team_id IS NOT NULL THEN
                DECLARE
                    _current_path ltree;
                    _new_root_path ltree;
                    _priority_label text;
                BEGIN
                    SELECT path INTO _current_path FROM priority WHERE id = _priority_id;
                    IF nlevel(_current_path) > 1 THEN
                        -- Generate a random root-level path (12 chars, ltree-safe)
                        _new_root_path := text2ltree(
                            substring(md5(random()::text || clock_timestamp()::text) from 1 for 12)
                        );
                        -- Move the priority and all descendants to the new root path
                        UPDATE priority
                        SET path = CASE
                            WHEN id = _priority_id THEN _new_root_path
                            ELSE _new_root_path || subpath(path, nlevel(_current_path))
                        END
                        WHERE path <@ _current_path;
                        -- Create priority_user entry to make this a root for the user
                        INSERT INTO priority_user (user_id, priority_id, personal)
                        VALUES (upsert_priority.user_id, _priority_id, FALSE)
                        ON CONFLICT (user_id, priority_id) DO NOTHING;
                    END IF;
                END;
            END IF;
            -- Propagate team_id to all descendants
            UPDATE priority
            SET team_id = _new_team_id
            WHERE path <@ (SELECT path FROM priority WHERE id = _priority_id)
            AND id != _priority_id;
        END IF;
    END IF;
    -- Update priority_setting for user-specific fields
    IF _is_visual_move THEN
        -- Visual move: create/update path alias
        INSERT INTO priority_setting (user_id, priority_id, key, value)
        VALUES (upsert_priority.user_id, _priority_id, 'path', to_jsonb(text(_input.path)))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
    END IF;
    -- Always upsert top_order, order, pomodoro, color if provided
    IF NOT _is_move THEN
        IF _input.top_order IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'top_order', to_jsonb(_input.top_order))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority.user_id AND priority_id = _priority_id AND key = 'top_order';
        END IF;
        IF _input."order" IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'order', to_jsonb(_input."order"))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        END IF;
        IF _input.pomodoro IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'pomodoro', to_jsonb(_input.pomodoro))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority.user_id AND priority_id = _priority_id AND key = 'pomodoro';
        END IF;
        IF _input.color IS NOT NULL THEN
            INSERT INTO priority_setting (user_id, priority_id, key, value)
            VALUES (upsert_priority.user_id, _priority_id, 'color', to_jsonb(COALESCE(_input.color, _priority_default_color)))
            ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        END IF;
    END IF;
    -- Return the updated row from the view
    SELECT
        * INTO v_row
    FROM
        "user".priority up
    WHERE
        up.user_id = upsert_priority.user_id
        AND up.id = _input.id;
    RETURN v_row;
END;
$$;
-- Create "propagate_team_id_to_descendants" function
CREATE FUNCTION "public"."propagate_team_id_to_descendants" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.team_id IS DISTINCT FROM OLD.team_id THEN
        UPDATE
            public.priority
        SET
            team_id = NEW.team_id
        WHERE
            path <@ NEW.path
            AND path != NEW.path
            AND (team_id IS DISTINCT FROM NEW.team_id);
    END IF;
    RETURN NEW;
END;
$$;
-- Create "propagate_team_id" function
CREATE FUNCTION "public"."propagate_team_id" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_parent_team_id bigint;
BEGIN
    IF NEW.team_id IS NULL AND nlevel (NEW.path) > 1 THEN
        SELECT
            team_id INTO v_parent_team_id
        FROM
            public.priority
        WHERE
            path = subpath (NEW.path, 0, nlevel (NEW.path) - 1);
        IF v_parent_team_id IS NOT NULL THEN
            NEW.team_id := v_parent_team_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
-- Modify "share_priority" function
CREATE OR REPLACE FUNCTION "public"."share_priority" ("p_user_id" uuid, "p_priority_id" uuid, "p_add_actor_ids" uuid[], "p_remove_actor_ids" uuid[], "p_role" text DEFAULT 'member') RETURNS jsonb LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_priority record;
    v_root_priority_id uuid;
    v_is_under_personal boolean := FALSE;
    v_old_path ltree;
    v_new_path ltree;
    v_extracted boolean := FALSE;
    v_actor_id uuid;
    v_contact record;
    v_priority_label text;
    v_recipient_org_root record;
    v_child record;
    v_relative ltree;
    v_target_path ltree;
BEGIN
    -- Validate user has access to the priority
    IF NOT public.user_has_priority_access (p_user_id, p_priority_id) THEN
        RAISE EXCEPTION 'User does not have access to this priority';
    END IF;
    -- Get priority details
    SELECT
        * INTO v_priority
    FROM
        public.priority
    WHERE
        id = p_priority_id;
    IF v_priority IS NULL THEN
        RAISE EXCEPTION 'Priority not found';
    END IF;
    v_old_path := v_priority.path;
    -- Check if extraction is needed:
    -- 1. Priority is NOT at top level (nlevel > 1)
    -- 2. Top-level priority is user's personal root
    IF nlevel (v_priority.path) > 1 THEN
        -- Get the root priority ID
        SELECT
            p.id INTO v_root_priority_id
        FROM
            public.priority p
        WHERE
            p.path = subltree (v_priority.path, 0, 1);
        -- Check if root is user's personal priority or an org root
        IF v_root_priority_id IS NOT NULL THEN
            SELECT
                EXISTS (
                    SELECT
                        1
                    FROM
                        public.priority_user pu
                        JOIN public.priority rp ON rp.id = pu.priority_id
                    WHERE
                        pu.priority_id = v_root_priority_id
                        AND pu.user_id = p_user_id
                        AND pu.personal = TRUE
                        AND pu.archived_at IS NULL) INTO v_is_under_personal;
        END IF;
    END IF;
    -- Perform extraction if needed
    IF v_is_under_personal THEN
        -- Generate new top-level path
        v_new_path := public.generate_path (NULL);
        -- Update priority and all descendants
        -- Extract the last label from the current path (the priority's own identifier)
        v_priority_label := ltree2text (subpath (v_old_path, -1));
        -- The new root path is the generated path for the priority itself
        -- For descendants, append their relative path from the old location
        UPDATE
            public.priority
        SET
            path = CASE WHEN path = v_old_path THEN
                v_new_path
            ELSE
                -- For descendants, replace the old path prefix with the new path
                text2ltree (ltree2text (v_new_path) || '.' || ltree2text (subpath (path, nlevel (v_old_path))))
            END
        WHERE
            path <@ v_old_path
            OR path = v_old_path;
        -- Create priority_setting with old path to preserve visual location
        INSERT INTO public.priority_setting (user_id, priority_id, key, value)
            VALUES (p_user_id, p_priority_id, 'path', to_jsonb(ltree2text(v_old_path)))
        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
        -- Create priority_user for current user (non-personal) for the extracted priority
        INSERT INTO public.priority_user (user_id, priority_id, personal)
            VALUES (p_user_id, p_priority_id, FALSE)
        ON CONFLICT (user_id, priority_id)
            DO UPDATE SET
                archived_at = NULL,
                personal = FALSE;
        v_extracted := TRUE;
        -- Re-nest previously extracted children back under the new path.
        -- When children were shared/extracted before the parent, they got their own
        -- top-level paths. Now that the parent is being shared, move them back under
        -- it so the hierarchy is correct for future sharing.
        FOR v_child IN
            SELECT ps.priority_id AS child_id,
                   (ps.value #>> '{}')::ltree AS alias_path,
                   cp.path AS current_path
            FROM public.priority_setting ps
            JOIN public.priority cp ON cp.id = ps.priority_id
            WHERE ps.user_id = p_user_id
              AND ps.key = 'path'
              AND (ps.value #>> '{}')::ltree <@ v_old_path
              AND (ps.value #>> '{}')::ltree != v_old_path
              AND NOT (cp.path <@ v_new_path)
            ORDER BY nlevel((ps.value #>> '{}')::ltree) ASC
        LOOP
            -- Compute relative position from old parent path
            -- e.g. alias 'k.plot.a' relative to old path 'k.plot' gives 'a'
            v_relative := subpath(v_child.alias_path, nlevel(v_old_path));
            v_target_path := v_new_path || v_relative;
            -- Move child and all its descendants under the new parent path
            UPDATE public.priority
            SET path = CASE
                WHEN path = v_child.current_path THEN v_target_path
                ELSE text2ltree(ltree2text(v_target_path) || '.' ||
                     ltree2text(subpath(path, nlevel(v_child.current_path))))
                END
            WHERE path <@ v_child.current_path;
            -- Delete the sharer's now-redundant path alias
            -- (it will be inherited from the parent's alias)
            DELETE FROM public.priority_setting
            WHERE user_id = p_user_id
              AND priority_id = v_child.child_id
              AND key = 'path';
        END LOOP;
    END IF;
    -- Ensure the sharer's own contact is in priority_contact
    INSERT INTO priority_contact (priority_id, contact_id)
    SELECT p_priority_id, c.id
    FROM contact c
    WHERE c.user_id = p_user_id AND c."primary" = TRUE AND c.archived_at IS NULL
    ON CONFLICT (priority_id, contact_id) DO NOTHING;
    -- Process additions
    IF p_add_actor_ids IS NOT NULL THEN
        FOREACH v_actor_id IN ARRAY p_add_actor_ids LOOP
            -- Get contact info to check if user_id is set
            SELECT
                * INTO v_contact
            FROM
                public.contact
            WHERE
                id = v_actor_id
                AND archived_at IS NULL;
            IF v_contact IS NULL THEN
                -- Skip invalid actor_ids
                CONTINUE;
            END IF;
            -- Create priority_contact for all contacts (both users and non-users)
            INSERT INTO public.priority_contact (priority_id, contact_id, invited_by, invited_at)
                VALUES (p_priority_id, v_actor_id, p_user_id, now())
            ON CONFLICT (priority_id, contact_id)
                DO UPDATE SET
                    invited_at = now(),
                    invited_by = COALESCE(priority_contact.invited_by, EXCLUDED.invited_by);
            -- Reset invitation sent_at if this is a re-invitation after full removal
            -- Only reset if the contact has no other active priority invitations
            WITH other_invitations AS (
                SELECT COUNT(*) as count
                FROM public.priority_contact
                WHERE contact_id = v_actor_id
                  AND invited_at IS NOT NULL
                  AND priority_id != p_priority_id
            )
            UPDATE public.contact_invitation
            SET sent_at = now()
            WHERE contact_id = v_actor_id
              AND (SELECT count FROM other_invitations) = 0;
            IF v_contact.user_id IS NOT NULL THEN
                -- Contact is an existing user - also create priority_user
                INSERT INTO public.priority_user (user_id, priority_id, personal, role)
                    VALUES (v_contact.user_id, p_priority_id, FALSE, p_role)
                ON CONFLICT (user_id, priority_id)
                    DO UPDATE SET
                        archived_at = NULL;
                -- If this is an org priority and recipient is an org member,
                -- create priority_settings to map it under their org root
                IF v_priority.team_id IS NOT NULL THEN
                    SELECT
                        p.id, p.path INTO v_recipient_org_root
                    FROM
                        public.priority p
                        JOIN public.priority_user pu ON pu.priority_id = p.id
                    WHERE
                        p.team_id = v_priority.team_id
                        AND pu.user_id = v_contact.user_id
                        AND pu.archived_at IS NULL
                        AND nlevel (p.path) = 1;
                    IF v_recipient_org_root IS NOT NULL THEN
                        -- Map shared priority visually under recipient's org root
                        INSERT INTO public.priority_setting (user_id, priority_id, key, value)
                            VALUES (v_contact.user_id, p_priority_id, 'path', to_jsonb(ltree2text(text2ltree(ltree2text(v_recipient_org_root.path) || '.' || ltree2text(subpath((SELECT path FROM public.priority WHERE id = p_priority_id), -1))))))
                        ON CONFLICT (user_id, priority_id, key) DO UPDATE SET value = EXCLUDED.value;
                    END IF;
                END IF;
            END IF;
        END LOOP;
    END IF;
    -- Process removals
    IF p_remove_actor_ids IS NOT NULL THEN
        FOREACH v_actor_id IN ARRAY p_remove_actor_ids LOOP
            -- Get contact info
            SELECT
                * INTO v_contact
            FROM
                public.contact
            WHERE
                id = v_actor_id;
            IF v_contact IS NULL THEN
                -- Skip invalid actor_ids
                CONTINUE;
            END IF;
            -- Cancel invitation for priority_contact (set invited_at to NULL)
            UPDATE
                public.priority_contact
            SET
                invited_at = NULL
            WHERE
                contact_id = v_actor_id
                AND priority_id = p_priority_id
                AND invited_at IS NOT NULL;
            IF v_contact.user_id IS NOT NULL THEN
                -- Archive priority_user for users
                UPDATE
                    public.priority_user
                SET
                    archived_at = now()
                WHERE
                    user_id = v_contact.user_id
                    AND priority_id = p_priority_id
                    AND archived_at IS NULL;
            END IF;
        END LOOP;
    END IF;
    -- Return result
    RETURN jsonb_build_object('id', p_priority_id, 'extracted', v_extracted, 'oldPath', CASE WHEN v_extracted THEN
            ltree2text (v_old_path)
        ELSE
            NULL
        END, 'newPath', CASE WHEN v_extracted THEN
            ltree2text (v_new_path)
        ELSE
            ltree2text (v_old_path)
        END);
END;
$$;
-- =====================================================================
-- Recreate the propagate triggers against the new team_id column.
-- The old triggers were dropped above; their functions are renamed below.
-- =====================================================================
CREATE TRIGGER "priority_propagate_team_id" BEFORE INSERT ON "public"."priority" FOR EACH ROW EXECUTE FUNCTION "public"."propagate_team_id"();
CREATE TRIGGER "priority_propagate_team_id_update" AFTER UPDATE OF "team_id" ON "public"."priority" FOR EACH ROW EXECUTE FUNCTION "public"."propagate_team_id_to_descendants"();
-- Rename the view column before the CREATE OR REPLACE below. CREATE OR
-- REPLACE VIEW refuses to change column names; ALTER VIEW RENAME COLUMN does.
ALTER VIEW "user"."priority" RENAME COLUMN "organization_id" TO "team_id";
-- Modify "priority" view
CREATE OR REPLACE VIEW "user"."priority" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "archived_at",
  "created_by",
  "updated_by",
  "root",
  "personal",
  "title",
  "path",
  "global_path",
  "top_order",
  "order",
  "pomodoro",
  "color",
  "key",
  "team_id",
  "unread",
  "role",
  "attention_window",
  "see_within_requests",
  "see_within_updates",
  "attention_window_set",
  "see_within_requests_set",
  "see_within_updates_set",
  "inherit_members"
) AS SELECT DISTINCT ON (user_id, id) user_id,
    id,
    created_at,
    updated_at,
    archived_at,
    created_by,
    updated_by,
    root,
    personal,
    title,
    path,
    global_path,
    top_order,
    "order",
    pomodoro,
    color,
    key,
    team_id,
    unread,
    role,
    attention_window,
    see_within_requests,
    see_within_updates,
    attention_window_set,
    see_within_requests_set,
    see_within_updates_set,
    inherit_members
   FROM ( SELECT pu.user_id,
            p.id,
            p.created_at,
            GREATEST(settings.updated_at, pu.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), inherited.updated_at) AS updated_at,
            GREATEST(pu.archived_at, p.archived_at) AS archived_at,
            p.created_by,
            p.updated_by,
            (pu.personal = true OR p.team_id IS NOT NULL) AND p.id = root.id AS root,
            user_root.path OPERATOR(public.@>) p.path AS personal,
            COALESCE(settings.title, p.title) AS title,
                CASE
                    WHEN inherited.path_value IS NOT NULL THEN
                    CASE
                        WHEN inherited.path_source IS NOT NULL AND p.path OPERATOR(public.<>) inherited.path_source::public.ltree AND public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree)) OPERATOR(public.<>) ''::public.ltree THEN inherited.path_value::public.ltree OPERATOR(public.||) public.subpath(p.path, public.nlevel(inherited.path_source::public.ltree))
                        ELSE inherited.path_value::public.ltree
                    END
                    WHEN user_root.path OPERATOR(public.@>) p.path THEN p.path
                    ELSE user_root.path OPERATOR(public.||) p.path
                END AS path,
            p.path AS global_path,
            settings.top_order,
            COALESCE(settings."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
            inherited.pomodoro,
            inherited.color,
            p.key,
            p.team_id,
            COALESCE(upu.unread, false) AS unread,
            "user".get_effective_role(pu.user_id, p.id) AS role,
            inherited.attention_window,
            inherited.see_within_requests,
            inherited.see_within_updates,
            COALESCE(settings.attention_window_set, false) AS attention_window_set,
            COALESCE(settings.see_within_requests_set, false) AS see_within_requests_set,
            COALESCE(settings.see_within_updates_set, false) AS see_within_updates_set,
            p.inherit_members,
                CASE
                    WHEN p.id = root.id THEN 0
                    ELSE public.nlevel(p.path) - public.nlevel(root.path)
                END AS _root_distance
           FROM public.priority_user pu
             JOIN public.priority root ON pu.priority_id = root.id
             JOIN public.priority_user pu_root ON pu.user_id = pu_root.user_id AND pu_root.personal = true
             JOIN public.priority user_root ON pu_root.priority_id = user_root.id
             JOIN public.priority p ON root.path OPERATOR(public.@>) p.path AND (p.id = root.id OR NOT (EXISTS ( SELECT 1
                   FROM public.priority blocker
                  WHERE blocker.path OPERATOR(public.<@) root.path AND p.path OPERATOR(public.<@) blocker.path AND blocker.path OPERATOR(public.<>) root.path AND blocker.inherit_members = false)))
             LEFT JOIN ( SELECT priority_setting.user_id,
                    priority_setting.priority_id,
                    max(
                        CASE
                            WHEN priority_setting.key = 'top_order'::text THEN (priority_setting.value #>> '{}'::text[])::double precision
                            ELSE NULL::double precision
                        END) AS top_order,
                    max(
                        CASE
                            WHEN priority_setting.key = 'order'::text THEN (priority_setting.value #>> '{}'::text[])::double precision
                            ELSE NULL::double precision
                        END) AS "order",
                    max(
                        CASE
                            WHEN priority_setting.key = 'title'::text THEN priority_setting.value #>> '{}'::text[]
                            ELSE NULL::text
                        END) AS title,
                    max(
                        CASE
                            WHEN priority_setting.key = 'attention_window'::text THEN 1
                            ELSE NULL::integer
                        END) IS NOT NULL AS attention_window_set,
                    max(
                        CASE
                            WHEN priority_setting.key = 'see_within_requests'::text THEN 1
                            ELSE NULL::integer
                        END) IS NOT NULL AS see_within_requests_set,
                    max(
                        CASE
                            WHEN priority_setting.key = 'see_within_updates'::text THEN 1
                            ELSE NULL::integer
                        END) IS NOT NULL AS see_within_updates_set,
                    max(priority_setting.updated_at) AS updated_at
                   FROM public.priority_setting
                  GROUP BY priority_setting.user_id, priority_setting.priority_id) settings ON settings.user_id = pu.user_id AND settings.priority_id = p.id
             LEFT JOIN ( SELECT priority_setting_inherited.user_id,
                    priority_setting_inherited.priority_id,
                    max(
                        CASE
                            WHEN priority_setting_inherited.key = 'pomodoro'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::integer
                            ELSE NULL::integer
                        END) AS pomodoro,
                    max(
                        CASE
                            WHEN priority_setting_inherited.key = 'color'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::integer
                            ELSE NULL::integer
                        END) AS color,
                    max(
                        CASE
                            WHEN priority_setting_inherited.key = 'attention_window'::text THEN priority_setting_inherited.value::text
                            ELSE NULL::text
                        END)::jsonb AS attention_window,
                    max(
                        CASE
                            WHEN priority_setting_inherited.key = 'see_within_requests'::text THEN priority_setting_inherited.value::text
                            ELSE NULL::text
                        END)::jsonb AS see_within_requests,
                    max(
                        CASE
                            WHEN priority_setting_inherited.key = 'see_within_updates'::text THEN priority_setting_inherited.value::text
                            ELSE NULL::text
                        END)::jsonb AS see_within_updates,
                    max(
                        CASE
                            WHEN priority_setting_inherited.key = 'path'::text THEN priority_setting_inherited.value #>> '{}'::text[]
                            ELSE NULL::text
                        END) AS path_value,
                    max(
                        CASE
                            WHEN priority_setting_inherited.key = 'path'::text THEN priority_setting_inherited.source_path::text
                            ELSE NULL::text
                        END) AS path_source,
                    max(priority_setting_inherited.updated_at) AS updated_at
                   FROM public.priority_setting_inherited
                  GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id) inherited ON inherited.user_id = pu.user_id AND inherited.priority_id = p.id
             LEFT JOIN "user".priority_unread upu ON upu.user_id = pu.user_id AND upu.priority_id = p.id
          WHERE pu.archived_at IS NULL) inner_q
  ORDER BY user_id, id, _root_distance;
-- Drop the old propagate_organization_id functions (their replacements were
-- created above as propagate_team_id / propagate_team_id_to_descendants).
DROP FUNCTION IF EXISTS "public"."propagate_organization_id" ();
DROP FUNCTION IF EXISTS "public"."propagate_organization_id_to_descendants" ();
