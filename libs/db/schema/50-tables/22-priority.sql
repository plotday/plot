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
    "team_id" bigint REFERENCES public."team" ON DELETE SET NULL,
    -- inherit_members is vestigial: with per-user priorities there are no
    -- cross-user subtree boundaries. It stays in the schema so the Flutter
    -- app's Drift store doesn't need an immediate migration; the API views
    -- no longer surface it and upsert_priority doesn't write it.
    "inherit_members" boolean NOT NULL DEFAULT TRUE,
    "default_thread_icon" text
);

-- Per-user owner lookups
CREATE INDEX idx_priority_user_id ON "public"."priority" ("user_id");

-- Paths are unique within a user's own tree, not globally.
CREATE UNIQUE INDEX idx_priority_user_path_unique ON "public"."priority" ("user_id", "path");

-- Index for priority path ltree queries (supports <@ operator)
-- Used heavily in user_activity view filtering
CREATE INDEX idx_priority_path_gist ON "public"."priority" USING gist ("path");

-- Ensure keys are unique within each priority root tree
CREATE UNIQUE INDEX idx_priority_key_per_root ON "public"."priority" ((subltree ("path", 0, 1)), "key")
WHERE
    "key" IS NOT NULL;

CREATE TRIGGER set_priority_updated_at
    BEFORE INSERT OR UPDATE ON "public"."priority"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

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

-- Determines who can access a priority and its descendants
CREATE TABLE "public"."priority_user" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "archived_at" timestamp with time zone,
    "personal" boolean NOT NULL DEFAULT FALSE,
    "role" text NOT NULL DEFAULT 'member',
    PRIMARY KEY (user_id, priority_id)
);

-- Ensure each user has max one personal priority
CREATE UNIQUE INDEX idx_priority_user_personal_user ON "public"."priority_user" ("user_id", "personal")
WHERE
    "personal" = TRUE;

-- Ensure each personal priority has max one user entry
CREATE UNIQUE INDEX idx_priority_user_personal_priority ON "public"."priority_user" ("priority_id", "personal")
WHERE
    "personal" = TRUE;

-- Index for user-based priority lookups in user_priority_base view
CREATE INDEX idx_priority_user_user_id ON "public"."priority_user" ("user_id")
WHERE
    archived_at IS NULL;

-- Optimized for user_priority_expanded GROUP BY operations
-- Supports efficient aggregation by user_id and priority_id with created_at
CREATE INDEX idx_priority_user_user_priority_archived ON "public"."priority_user" ("user_id", "priority_id", "created_at")
WHERE
    archived_at IS NULL;

-- Index for joins on priority_id alone (PK is user_id, priority_id which doesn't help)
-- Used in user_priority view: pu.priority_id = root.id
CREATE INDEX idx_priority_user_priority_id ON "public"."priority_user" ("priority_id");

CREATE TRIGGER set_priority_user_updated_at
    BEFORE INSERT OR UPDATE ON "public"."priority_user"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_user_created_at
    BEFORE INSERT ON "public"."priority_user"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

-- The old insert_priority_user AFTER INSERT trigger is retired. Priority
-- ownership is now carried directly on priority.user_id, populated by
-- the default_priority_user_id BEFORE INSERT trigger above. Nothing
-- needs to write priority_user anymore — it stays around purely for
-- legacy readers until Stage 4d removes it.

CREATE OR REPLACE FUNCTION propagate_team_id ()
    RETURNS TRIGGER
    AS $$
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
$$
LANGUAGE plpgsql;

CREATE TRIGGER priority_propagate_team_id
    BEFORE INSERT ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION propagate_team_id ();

-- When team_id changes on a priority, propagate to all descendants
CREATE OR REPLACE FUNCTION propagate_team_id_to_descendants ()
    RETURNS TRIGGER
    AS $$
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
$$
LANGUAGE plpgsql;

CREATE TRIGGER priority_propagate_team_id_update
    AFTER UPDATE OF team_id ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION propagate_team_id_to_descendants ();

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

