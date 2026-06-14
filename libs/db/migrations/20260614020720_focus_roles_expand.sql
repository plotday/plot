-- Create "role" table
CREATE TABLE "public"."role" (
  "id" uuid NOT NULL DEFAULT uuidv7(),
  "created_at" timestamptz NOT NULL DEFAULT now(),
  "updated_at" timestamptz NOT NULL DEFAULT now(),
  "created_by" uuid NOT NULL,
  "user_id" uuid NOT NULL,
  "archived_at" timestamptz NULL,
  "name" text NOT NULL,
  "color" integer NOT NULL DEFAULT 0,
  "order" double precision NULL,
  "early_notifications_enabled" boolean NULL,
  "notify_window" jsonb NULL,
  "see_within" jsonb NULL,
  "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
  PRIMARY KEY ("id"),
  CONSTRAINT "role_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE,
  CONSTRAINT "role_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user" ("id") ON UPDATE NO ACTION ON DELETE CASCADE
);
-- Create index "idx_role_seq" to table: "role"
CREATE INDEX "idx_role_seq" ON "public"."role" ("seq");
-- Create index "idx_role_user_id" to table: "role"
CREATE INDEX "idx_role_user_id" ON "public"."role" ("user_id");
-- Create "apply_role_change_to_focus" function
CREATE FUNCTION "public"."apply_role_change_to_focus" () RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    old_role public.role%ROWTYPE;
    new_role public.role%ROWTYPE;
BEGIN
    IF NEW.role_id IS NOT DISTINCT FROM OLD.role_id THEN
        RETURN NEW;
    END IF;
    IF NEW.role_id IS NULL THEN
        RETURN NEW;  -- focus cleared of its role; nothing to follow
    END IF;
    SELECT * INTO new_role FROM public.role WHERE id = NEW.role_id;
    IF new_role.id IS NULL THEN
        RETURN NEW;  -- dangling role_id; leave the focus's values as-is
    END IF;
    -- old_role is a NULL/zero row when OLD.role_id IS NULL (a focus getting its
    -- first role). Then `NEW.x IS NOT DISTINCT FROM old_role.x` is true only when
    -- NEW.x is NULL, so a value-less focus adopts the new role while a
    -- concrete-valued focus keeps its value as an override — the intended rule.
    SELECT * INTO old_role FROM public.role WHERE id = OLD.role_id;

    -- The Inbox always follows its (new) role.
    IF NEW.is_inbox THEN
        NEW.color := new_role.color;
        NEW.early_notifications_enabled := new_role.early_notifications_enabled;
        NEW.notify_window := new_role.notify_window;
        NEW.see_within := new_role.see_within;
        RETURN NEW;
    END IF;

    IF NEW.color IS NOT DISTINCT FROM old_role.color THEN
        NEW.color := new_role.color;
    END IF;

    IF NEW.early_notifications_enabled IS NOT DISTINCT FROM old_role.early_notifications_enabled
        AND NEW.notify_window IS NOT DISTINCT FROM old_role.notify_window
        AND NEW.see_within IS NOT DISTINCT FROM old_role.see_within THEN
        NEW.early_notifications_enabled := new_role.early_notifications_enabled;
        NEW.notify_window := new_role.notify_window;
        NEW.see_within := new_role.see_within;
    END IF;

    RETURN NEW;
END;
$$;
-- Modify "priority" table
ALTER TABLE "public"."priority" ADD COLUMN "role_id" uuid NULL, ADD COLUMN "is_inbox" boolean NOT NULL DEFAULT false, ADD COLUMN "early_notifications_enabled" boolean NULL, ADD COLUMN "notify_window" jsonb NULL, ADD COLUMN "see_within" jsonb NULL, ADD CONSTRAINT "priority_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."role" ("id") ON UPDATE NO ACTION ON DELETE NO ACTION;
-- Create index "idx_priority_role_id" to table: "priority"
CREATE INDEX "idx_priority_role_id" ON "public"."priority" ("role_id");
-- Create index "idx_priority_role_inbox" to table: "priority"
CREATE UNIQUE INDEX "idx_priority_role_inbox" ON "public"."priority" ("role_id") WHERE (is_inbox AND (archived_at IS NULL));
-- Create trigger "apply_role_change_to_focus"
CREATE TRIGGER "apply_role_change_to_focus" BEFORE UPDATE OF "role_id" ON "public"."priority" FOR EACH ROW EXECUTE FUNCTION "public"."apply_role_change_to_focus"();
-- Create "default_role_user_id" function
CREATE FUNCTION "public"."default_role_user_id" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.user_id IS NULL THEN
        NEW.user_id := NEW.created_by;
    END IF;
    -- Default sidebar order to creation time so new roles append.
    IF NEW."order" IS NULL THEN
        NEW."order" := extract(epoch FROM now()) * 1000;
    END IF;
    RETURN NEW;
END;
$$;
-- Create trigger "default_role_user_id"
CREATE TRIGGER "default_role_user_id" BEFORE INSERT ON "public"."role" FOR EACH ROW EXECUTE FUNCTION "public"."default_role_user_id"();
-- Create trigger "set_role_created_at"
CREATE TRIGGER "set_role_created_at" BEFORE INSERT ON "public"."role" FOR EACH ROW EXECUTE FUNCTION "public"."set_created_at"();
-- Create trigger "set_role_created_by"
CREATE TRIGGER "set_role_created_by" BEFORE INSERT ON "public"."role" FOR EACH ROW EXECUTE FUNCTION "public"."update_created_by"();
-- Create trigger "set_role_updated_at"
CREATE TRIGGER "set_role_updated_at" BEFORE INSERT OR UPDATE ON "public"."role" FOR EACH ROW EXECUTE FUNCTION "public"."update_seq_and_updated_at"();
-- Create "propagate_role_to_focuses" function
CREATE FUNCTION "public"."propagate_role_to_focuses" () RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.color IS DISTINCT FROM OLD.color THEN
        UPDATE priority
        SET color = NEW.color
        WHERE role_id = NEW.id
          AND archived_at IS NULL
          AND (is_inbox OR color IS NOT DISTINCT FROM OLD.color);
    END IF;

    IF NEW.early_notifications_enabled IS DISTINCT FROM OLD.early_notifications_enabled
        OR NEW.notify_window IS DISTINCT FROM OLD.notify_window
        OR NEW.see_within IS DISTINCT FROM OLD.see_within THEN
        UPDATE priority
        SET early_notifications_enabled = NEW.early_notifications_enabled,
            notify_window = NEW.notify_window,
            see_within = NEW.see_within
        WHERE role_id = NEW.id
          AND archived_at IS NULL
          AND (is_inbox OR (
              early_notifications_enabled IS NOT DISTINCT FROM OLD.early_notifications_enabled
              AND notify_window IS NOT DISTINCT FROM OLD.notify_window
              AND see_within IS NOT DISTINCT FROM OLD.see_within));
    END IF;

    RETURN NEW;
END;
$$;
-- Create trigger "propagate_role_to_focuses"
CREATE TRIGGER "propagate_role_to_focuses" AFTER UPDATE ON "public"."role" FOR EACH ROW EXECUTE FUNCTION "public"."propagate_role_to_focuses"();
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
    _is_move boolean;
    _priority_exists boolean;
    _old_path ltree;
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
        _old_path := _old.path;
    END IF;
    -- Flat-client compatibility: clients on the flattened model (apiVersion
    -- >= 4) have no nesting and do not send a path. Keep the existing path on
    -- update; on insert synthesize a child-of-root path so nested (old)
    -- clients can still place the new focus under the user's root. path is
    -- NOT NULL, so this must never leave it null.
    IF _input.path IS NULL THEN
        IF _priority_exists THEN
            _input.path := _old_path;
        ELSE
            DECLARE
                _root_path ltree;
            BEGIN
                SELECT
                    path INTO _root_path
                FROM priority
                WHERE user_id = upsert_priority.user_id AND nlevel(path) = 1
                ORDER BY created_at ASC
                LIMIT 1;
                IF _root_path IS NULL THEN
                    -- No root yet: treat this as the root itself.
                    _input.path := generate_path(NULL);
                ELSE
                    _input.path := _root_path || generate_path(NULL);
                END IF;
            END;
        END IF;
    END IF;
    -- Detect if this is a move (path changed on existing priority)
    _is_move := (_priority_exists
        AND _input.path IS DISTINCT FROM _old_path);
    IF _is_move THEN
        -- Prevent circular reference
        IF _input.path <@ _old_path OR _input.path = _old_path THEN
            RAISE EXCEPTION 'Cannot move priority to be a descendant of itself'
                USING HINT = 'old_path=' || _old_path::text || ', new_path=' || _input.path::text;
        END IF;
        -- In the per-user model every priority belongs to a single user's
        -- tree, so every move is a straight ltree relocation.
        DECLARE
            _parent_path ltree;
        BEGIN
            IF nlevel(_input.path) > 1 THEN
                _parent_path := subpath(_input.path, 0, nlevel(_input.path) - 1);
            ELSE
                _parent_path := NULL;
            END IF;
            PERFORM move_priority (_input.id, _parent_path);
        END;
    END IF;
    -- Get the priority's default color for initializing new priority_settings
    SELECT
        color INTO _priority_default_color
    FROM
        priority
    WHERE
        id = _input.id;
    -- For a NEW focus, default the role + colour so it starts out following a
    -- role. Existing focuses keep their stored role (role change is modal-only
    -- and guarded by present-key semantics in the ON CONFLICT branch below).
    IF NOT _priority_exists THEN
        -- Role: explicit from input (API >= 5), else the user's first role
        -- (their Personal role). Every user has >= 1 role after backfill /
        -- activation, so this is non-null for live focuses.
        IF _input.role_id IS NULL THEN
            SELECT id INTO _input.role_id
            FROM public.role
            WHERE user_id = upsert_priority.user_id AND archived_at IS NULL
            ORDER BY created_at ASC
            LIMIT 1;
        END IF;
        -- Colour: the creator's chosen colour, else the role's colour, so a
        -- new focus starts out following its role.
        IF _input.color IS NULL THEN
            SELECT color INTO _input.color
            FROM public.role
            WHERE id = _input.role_id;
        END IF;
    END IF;
    -- Update priority table
    IF NOT _is_move THEN
        INSERT INTO priority (id, user_id, archived_at, title, color, icon, path, role_id, created_by, updated_by, description, notification_cleared_at)
            VALUES (_input.id, upsert_priority.user_id, _input.archived_at, _input.title, CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    NULL
                END, _input.icon, _input.path, _input.role_id, _input.created_by, _input.updated_by, p_priority ->> 'description', _input.notification_cleared_at)
        ON CONFLICT (id)
            DO UPDATE SET
                archived_at = _input.archived_at,
                title = _input.title,
                color = CASE WHEN _is_creator THEN
                    _input.color
                ELSE
                    priority.color
                END,
                -- COALESCE: old (nested) clients don't send icon; preserve the
                -- existing value rather than wiping it on every edit.
                icon = COALESCE(_input.icon, priority.icon),
                updated_by = _input.updated_by,
                -- Present-key semantics: only overwrite description when the
                -- caller actually sent it; preserve it otherwise. facet_filters
                -- is owned by the server-side derivation, never set here.
                description = CASE WHEN p_priority ? 'description'
                    THEN p_priority ->> 'description' ELSE priority.description END,
                -- Role change is modal-only (API >= 5): only move the focus when
                -- the caller explicitly sent role_id, so old clients (which don't
                -- send it) never reassign the focus. A non-null sent role_id fires
                -- apply_role_change_to_focus (BEFORE UPDATE OF role_id) for
                -- follow-if-matching colour/notification adoption.
                role_id = CASE WHEN (p_priority ? 'role_id') AND _input.role_id IS NOT NULL
                    THEN _input.role_id ELSE priority.role_id END,
                notification_cleared_at = GREATEST(priority.notification_cleared_at, _input.notification_cleared_at)
            RETURNING
                id INTO _priority_id;
    ELSE
        -- For moves, just update non-path fields (path was already updated by move_priority)
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
            icon = COALESCE(_input.icon, priority.icon),
            updated_by = _input.updated_by,
            notification_cleared_at = GREATEST(priority.notification_cleared_at, _input.notification_cleared_at)
        WHERE
            id = _input.id
        RETURNING
            id INTO _priority_id;
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
        ELSE
            DELETE FROM priority_setting
            WHERE user_id = upsert_priority.user_id AND priority_id = _priority_id AND key = 'color';
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
-- Modify "upsert_priority_attention" function
CREATE OR REPLACE FUNCTION "user"."upsert_priority_attention" ("p_user_id" uuid, "p_priority_id" uuid, "p_early_notifications_enabled" boolean DEFAULT NULL::boolean, "p_set_early_notifications_enabled" boolean DEFAULT false, "p_notify_window" jsonb DEFAULT NULL::jsonb, "p_set_notify_window" boolean DEFAULT false, "p_see_within" jsonb DEFAULT NULL::jsonb, "p_set_see_within" boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SET "search_path" = public, "user" AS $$
BEGIN
    PERFORM "user".assert_priority_access(p_user_id, p_priority_id);

    -- Notifications are concrete columns on priority now (follow-if-matching;
    -- see 95-triggers/30-role-propagation.sql). Old clients send "set + null =
    -- inherit"; there is no inherit anymore, so a null value means "follow the
    -- role" — resolve it to the focus's role's current value via scalar
    -- subqueries (which yield NULL when the focus has no role yet, pre-backfill;
    -- NULL = app default).
    UPDATE public.priority p
    SET early_notifications_enabled = CASE
            WHEN p_set_early_notifications_enabled THEN
                COALESCE(p_early_notifications_enabled,
                    (SELECT r.early_notifications_enabled FROM public.role r WHERE r.id = p.role_id))
            ELSE p.early_notifications_enabled END,
        notify_window = CASE
            WHEN p_set_notify_window THEN
                COALESCE(p_notify_window,
                    (SELECT r.notify_window FROM public.role r WHERE r.id = p.role_id))
            ELSE p.notify_window END,
        see_within = CASE
            WHEN p_set_see_within THEN
                COALESCE(p_see_within,
                    (SELECT r.see_within FROM public.role r WHERE r.id = p.role_id))
            ELSE p.see_within END
    WHERE p.id = p_priority_id AND p.user_id = p_user_id;

    -- The UPDATE above fires set_priority_updated_at, bumping priority.seq so
    -- the user view re-emits with the new values.
END;
$$;
-- Create "role" view
CREATE VIEW "user"."role" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "created_by",
  "name",
  "color",
  "order",
  "early_notifications_enabled",
  "notify_window",
  "see_within"
) AS SELECT user_id,
    id,
    created_at,
    updated_at,
    seq,
    archived_at,
    created_by,
    name,
    color,
    "order",
    early_notifications_enabled,
    notify_window,
    see_within
   FROM public.role r;
-- Modify "priority" view
CREATE OR REPLACE VIEW "user"."priority" (
  "user_id",
  "id",
  "created_at",
  "updated_at",
  "seq",
  "archived_at",
  "created_by",
  "updated_by",
  "root",
  "title",
  "path",
  "global_path",
  "top_order",
  "order",
  "pomodoro",
  "color",
  "key",
  "unread",
  "role",
  "respond_schedule_enabled",
  "respond_window",
  "respond_within",
  "early_notifications_enabled",
  "notify_window",
  "see_within",
  "respond_schedule_enabled_set",
  "respond_window_set",
  "respond_within_set",
  "early_notifications_enabled_set",
  "notify_window_set",
  "see_within_set",
  "inherit_members",
  "config",
  "icon",
  "notification_cleared_at",
  "role_id",
  "is_inbox"
) AS WITH user_root AS (
         SELECT DISTINCT ON (p_1.user_id) p_1.user_id,
            p_1.id AS root_id,
            p_1.path AS root_path
           FROM public.priority p_1
          WHERE public.nlevel(p_1.path) = 1
          ORDER BY p_1.user_id, p_1.created_at
        ), direct_settings AS (
         SELECT priority_setting.user_id,
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
                    WHEN priority_setting.key = 'color'::text THEN (priority_setting.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS color,
            max(
                CASE
                    WHEN priority_setting.key = 'respond_schedule_enabled'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS respond_schedule_enabled_set,
            max(
                CASE
                    WHEN priority_setting.key = 'respond_window'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS respond_window_set,
            max(
                CASE
                    WHEN priority_setting.key = 'respond_within'::text THEN 1
                    ELSE NULL::integer
                END) IS NOT NULL AS respond_within_set,
            max(priority_setting.updated_at) AS updated_at
           FROM public.priority_setting
          GROUP BY priority_setting.user_id, priority_setting.priority_id
        ), inherited_settings AS (
         SELECT priority_setting_inherited.user_id,
            priority_setting_inherited.priority_id,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'pomodoro'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::integer
                    ELSE NULL::integer
                END) AS pomodoro,
            bool_or(
                CASE
                    WHEN priority_setting_inherited.key = 'respond_schedule_enabled'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::boolean
                    ELSE NULL::boolean
                END) AS respond_schedule_enabled,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'respond_window'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS respond_window,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'respond_within'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS respond_within,
            bool_or(
                CASE
                    WHEN priority_setting_inherited.key = 'early_notifications_enabled'::text THEN (priority_setting_inherited.value #>> '{}'::text[])::boolean
                    ELSE NULL::boolean
                END) AS early_notifications_enabled,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'notify_window'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS notify_window,
            max(
                CASE
                    WHEN priority_setting_inherited.key = 'see_within'::text THEN priority_setting_inherited.value::text
                    ELSE NULL::text
                END)::jsonb AS see_within,
            max(priority_setting_inherited.updated_at) AS updated_at
           FROM public.priority_setting_inherited
          GROUP BY priority_setting_inherited.user_id, priority_setting_inherited.priority_id
        )
 SELECT p.user_id,
    p.id,
    p.created_at,
    GREATEST(direct.updated_at, p.updated_at, COALESCE(upu.updated_at, '1970-01-01 00:00:00+00'::timestamp with time zone), inh.updated_at) AS updated_at,
    p.seq,
    p.archived_at,
    p.created_by,
    p.updated_by,
    p.id = ur.root_id AS root,
    COALESCE(direct.title, p.title) AS title,
    p.path,
    p.path AS global_path,
    direct.top_order,
    COALESCE(direct."order", (EXTRACT(epoch FROM p.created_at) * 1000::numeric)::double precision) AS "order",
    inh.pomodoro,
    COALESCE(direct.color, p.color) AS color,
    p.key,
    COALESCE(upu.unread, false) AS unread,
    'member'::text AS role,
    inh.respond_schedule_enabled,
    inh.respond_window,
    inh.respond_within,
    p.early_notifications_enabled,
    p.notify_window,
    p.see_within,
    COALESCE(direct.respond_schedule_enabled_set, false) AS respond_schedule_enabled_set,
    COALESCE(direct.respond_window_set, false) AS respond_window_set,
    COALESCE(direct.respond_within_set, false) AS respond_within_set,
    p.early_notifications_enabled IS NOT NULL AS early_notifications_enabled_set,
    p.notify_window IS NOT NULL AS notify_window_set,
    p.see_within IS NOT NULL AS see_within_set,
    p.inherit_members,
    p.config,
    p.icon,
    p.notification_cleared_at,
    p.role_id,
    p.is_inbox
   FROM public.priority p
     LEFT JOIN user_root ur ON ur.user_id = p.user_id
     LEFT JOIN direct_settings direct ON direct.user_id = p.user_id AND direct.priority_id = p.id
     LEFT JOIN inherited_settings inh ON inh.user_id = p.user_id AND inh.priority_id = p.id
     LEFT JOIN "user".priority_unread upu ON upu.user_id = p.user_id AND upu.priority_id = p.id;

-- === Backfill: one Personal role per user; adopt root as its Inbox. ===

-- One Personal role per user (colour theme 0, app-default notifications).
INSERT INTO role (id, user_id, created_by, name, color)
SELECT uuidv7(), u.id, u.id, 'Personal', 0
FROM "user" u
WHERE NOT EXISTS (SELECT 1 FROM role r WHERE r.user_id = u.id);

-- File every existing focus under its user's (only) role.
UPDATE priority p
SET role_id = (SELECT r.id FROM role r WHERE r.user_id = p.user_id ORDER BY r.created_at ASC LIMIT 1)
WHERE p.role_id IS NULL;

-- The existing single root priority becomes the role's Inbox. Guard against
-- users with multiple non-archived roots (seed/legacy data): pick the oldest
-- root per user so at most one Inbox exists per user.
UPDATE priority p
SET is_inbox = TRUE
WHERE p.id IN (
    SELECT DISTINCT ON (user_id) id
    FROM priority
    WHERE nlevel(path) = 1 AND archived_at IS NULL
    ORDER BY user_id, created_at ASC
);

-- Resolve a concrete colour: explicit per-user 'color' setting, else the
-- focus's own colour, else theme 0.
UPDATE priority p
SET color = COALESCE(
    (SELECT (ps.value #>> '{}')::integer FROM priority_setting ps
       WHERE ps.priority_id = p.id AND ps.user_id = p.user_id AND ps.key = 'color'),
    p.color, 0)
WHERE p.color IS NULL OR EXISTS (
    SELECT 1 FROM priority_setting ps
    WHERE ps.priority_id = p.id AND ps.user_id = p.user_id AND ps.key = 'color');

-- Copy the EFFECTIVE (inherited) notification settings into the new columns,
-- so focuses keep what they were actually showing. priority_setting_inherited
-- still exists during the expand phase (Plan 6 removes it).
UPDATE priority p
SET early_notifications_enabled = psi.early_notifications_enabled,
    notify_window = psi.notify_window,
    see_within = psi.see_within
FROM (
    SELECT user_id, priority_id,
        BOOL_OR(CASE WHEN key = 'early_notifications_enabled' THEN (value #>> '{}')::boolean END) AS early_notifications_enabled,
        MAX(CASE WHEN key = 'notify_window' THEN value::text END)::jsonb AS notify_window,
        MAX(CASE WHEN key = 'see_within' THEN value::text END)::jsonb AS see_within
    FROM priority_setting_inherited
    GROUP BY user_id, priority_id
) psi
WHERE psi.priority_id = p.id AND psi.user_id = p.user_id;

-- Seed each role's colour + notification template from its Inbox's resolved
-- settings, so an existing custom root colour and the user's notification
-- preference become the role template (theme 0 remains the result when the
-- root had no explicit colour). The Inbox then trivially follows its role.
UPDATE role r
SET color = p.color,
    early_notifications_enabled = p.early_notifications_enabled,
    notify_window = p.notify_window,
    see_within = p.see_within
FROM priority p
WHERE p.role_id = r.id AND p.is_inbox AND p.archived_at IS NULL;

-- The Inbox always follows its role: force its colour and notifications to the
-- role's values (notifications already match after the seed above).
UPDATE priority p
SET color = r.color,
    early_notifications_enabled = r.early_notifications_enabled,
    notify_window = r.notify_window,
    see_within = r.see_within
FROM role r
WHERE p.role_id = r.id AND p.is_inbox;

-- Bump priority.seq so every client re-pulls and picks up the new columns
-- (per libs/db/AGENTS.md "Also bump on schema changes that add view columns").
UPDATE priority SET updated_at = now();
