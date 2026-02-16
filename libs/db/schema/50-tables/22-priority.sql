CREATE TABLE "public"."priority" (
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    -- All fields added below must be handled in handle_user_priority_upsert
    "archived_at" timestamp with time zone,
    "title" text NOT NULL,
    "color" integer,
    "path" ltree NOT NULL UNIQUE,
    "updated_by" integer NOT NULL DEFAULT 0,
    "sync_depth" integer,
    "key" text
);

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

-- Determines who can access a priority and its descendants
CREATE TABLE "public"."priority_user" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "archived_at" timestamp with time zone,
    "personal" boolean NOT NULL DEFAULT FALSE,
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

CREATE OR REPLACE FUNCTION insert_priority_user ()
    RETURNS TRIGGER
    AS $$
BEGIN
    -- Only create entry for new, top-level priorities, and mark them as personal
    -- Skip global priorities (those with keys starting with @, except @plot which is user-specific)
    IF nlevel (NEW.path) = 1 AND (NEW.key IS NULL OR NEW.key = '@plot' OR NOT NEW.key LIKE '@%') THEN
        INSERT INTO public.priority_user (user_id, priority_id, personal)
            VALUES (NEW.created_by, NEW.id, TRUE);
    END IF;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER priority_insert_trigger
    AFTER INSERT ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION insert_priority_user ();

-- Per-user priority settings
CREATE TABLE "public"."priority_settings" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    -- All fields added below must be handled in handle_user_priority_upsert
    "top_order" double precision,
    "order" double precision,
    -- The fields below are inherited by sub-priorities
    -- If path is set, it overrides the sub-path below the root
    "path" ltree,
    "pomodoro" integer,
    "color" integer,
    "title" text,
    PRIMARY KEY (user_id, priority_id)
);

CREATE TRIGGER set_priority_settings_updated_at
    BEFORE INSERT OR UPDATE ON "public"."priority_settings"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

