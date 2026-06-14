CREATE TABLE "public"."priority" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    -- Per-user owner. Single source of truth for who sees this priority.
    -- Populated automatically by set_priority_user_id BEFORE INSERT
    -- (trigger defined below) from created_by, so callers don't need to
    -- pass it explicitly.
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    -- All fields added below must be handled in handle_user_priority_upsert
    "archived_at" timestamp with time zone,
    "title" text NOT NULL,
    "color" integer,
    -- Paths are now scoped per user: two users can each have a priority
    -- at path 'work', and matches of descendant paths are filtered by
    -- user_id in priority_expanded / priority_child.
    "path" ltree NOT NULL,
    "updated_by" integer NOT NULL DEFAULT 0,
    "sync_depth" integer,
    "key" text,
    -- inherit_members is vestigial: with per-user priorities there are no
    "inherit_members" boolean NOT NULL DEFAULT TRUE,
    "default_thread_icon" text,
    -- The focus's own icon: a curated FontAwesome key string (see
    -- kFocusIcons in the Flutter app). Distinct from default_thread_icon,
    -- which sets the icon for threads filed under this priority. NULL =
    -- the client renders the default focus icon.
    "icon" text,
    -- Sparse per-priority configuration. Not user-editable; set directly in
    -- the DB. Recognized keys: topic (string, default thread.topic),
    -- view ('activity' to hide the agenda tab on the priority page).
    "config" jsonb,
    "facet_filters" jsonb,
    "description" text,
    -- Role grouping (Plan: focus-roles). Every focus belongs to a role except
    -- the single global FYI focus; enforced by the priority_role_or_fyi CHECK
    -- below. Kept nullable at the column level precisely so the FYI row
    -- (role_id NULL, is_fyi TRUE) is allowed — a plain NOT NULL would reject it.
    "role_id" uuid REFERENCES public.role,
    -- Marks the role's single auto-managed Inbox focus. Partial-unique below.
    "is_inbox" boolean NOT NULL DEFAULT FALSE,
    -- Marks the user's single global FYI focus (low-signal mail). Role-less
    -- (role_id IS NULL); partial-unique per user below. Server-managed. This is
    -- the only focus permitted to have a NULL role_id (see priority_role_or_fyi).
    "is_fyi" boolean NOT NULL DEFAULT FALSE,
    -- Concrete notification settings the focus follows from its role
    -- (see 95-triggers/30-role-propagation.sql). NULL = app default.
    "early_notifications_enabled" boolean,
    "notify_window" jsonb,
    "see_within" jsonb,
    "notification_cleared_at" timestamp with time zone,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    -- Every focus must belong to a role, except the single global FYI focus
    -- (intentionally role-less). focus-roles wires role_id into every creation
    -- path, with default_role_id() as the fallback for paths that don't supply
    -- one. This supersedes the once-planned `ALTER COLUMN role_id SET NOT NULL`
    -- contract step, which would have rejected the FYI row (role_id NULL).
    CONSTRAINT priority_role_or_fyi CHECK ("role_id" IS NOT NULL OR "is_fyi")
);

-- Per-user owner lookups
CREATE INDEX idx_priority_user_id ON "public"."priority" ("user_id");

-- Paths are unique within a user's own tree, not globally.
CREATE UNIQUE INDEX idx_priority_user_path_unique ON "public"."priority" ("user_id", "path");

-- Index for priority path ltree queries (supports <@ operator)
-- Used heavily in user_thread view filtering
CREATE INDEX idx_priority_path_gist ON "public"."priority" USING gist ("path");

CREATE INDEX idx_priority_seq ON "public"."priority" ("seq");

-- At most one live Inbox focus per role.
CREATE UNIQUE INDEX idx_priority_role_inbox ON "public"."priority" ("role_id")
WHERE
    "is_inbox" AND "archived_at" IS NULL;

-- At most one live FYI focus per user. Keyed on user_id (not role_id) because
-- the FYI focus is role-less, so role_id is NULL and can't be the unique key.
CREATE UNIQUE INDEX idx_priority_user_fyi ON "public"."priority" ("user_id")
WHERE
    "is_fyi" AND "archived_at" IS NULL;

-- Role membership lookups.
CREATE INDEX idx_priority_role_id ON "public"."priority" ("role_id");

-- Ensure keys are unique within each priority root tree
CREATE UNIQUE INDEX idx_priority_key_per_root ON "public"."priority" ((subltree ("path", 0, 1)), "key")
WHERE
    "key" IS NOT NULL;

CREATE TRIGGER set_priority_updated_at
    BEFORE INSERT OR UPDATE ON "public"."priority"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_priority_created_at
    BEFORE INSERT ON "public"."priority"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

CREATE TRIGGER set_priority_created_by
    BEFORE INSERT ON "public"."priority"
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

-- Default priority.user_id to the creator when the caller doesn't set it.
-- Runs BEFORE INSERT so existing upsert RPCs and direct inserts that
-- don't know about the new column still satisfy the NOT NULL constraint.
CREATE OR REPLACE FUNCTION public.default_priority_user_id ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.user_id IS NULL THEN
        NEW.user_id := NEW.created_by;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER default_priority_user_id
    BEFORE INSERT ON "public"."priority"
    FOR EACH ROW
    EXECUTE FUNCTION public.default_priority_user_id ();

-- Per-user priority settings (per-key with JSONB values)
CREATE TABLE "public"."priority_setting" (
    "updated_at" timestamptz NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "key" text NOT NULL,
    "value" jsonb NOT NULL,
    PRIMARY KEY (user_id, priority_id, key)
);

CREATE TRIGGER set_priority_setting_updated_at
    BEFORE INSERT OR UPDATE ON "public"."priority_setting"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

-- Enforce single root in priority table
CREATE OR REPLACE FUNCTION public.validate_priority_root ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_root_path ltree;
BEGIN
    -- Ensure each user has only one root priority (nlevel=1)
    IF nlevel(NEW.path) = 1 THEN
        IF EXISTS (
            SELECT 1 FROM priority
            WHERE user_id = NEW.user_id AND nlevel(path) = 1 AND id != NEW.id
        ) THEN
            RAISE EXCEPTION 'User already has a root priority';
        END IF;
    ELSE
        -- Ensure all other priorities are descendants of the root
        SELECT path INTO v_root_path
        FROM priority
        WHERE user_id = NEW.user_id AND nlevel(path) = 1;

        IF v_root_path IS NULL THEN
            -- Root might be being inserted in the same transaction
            -- (e.g. by activate_invited_user). If no root yet exists,
            -- and this isn't a root, it's invalid.
            RAISE EXCEPTION 'User must have a root priority before adding sub-priorities';
        END IF;

        IF NOT v_root_path @> NEW.path THEN
            RAISE EXCEPTION 'Priority path % must be under root path %', NEW.path, v_root_path;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER validate_priority_root_trigger
    BEFORE INSERT OR UPDATE OF path, user_id ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION public.validate_priority_root ();

