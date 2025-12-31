CREATE TABLE "public"."priority" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "root" boolean NOT NULL DEFAULT FALSE,
    -- All fields added below must be handled in handle_user_priority_upsert
    "archived_at" timestamp with time zone,
    "title" text NOT NULL,
    "color" integer,
    "path" ltree NOT NULL UNIQUE,
    "updated_by" integer NOT NULL DEFAULT 0
);

CREATE UNIQUE INDEX idx_priority_created_by_root_true ON "public"."priority" ("created_by")
WHERE
    "root" = TRUE;

-- Index for priority path ltree queries (supports <@ operator)
-- Used heavily in user_activity view filtering
CREATE INDEX idx_priority_path_gist ON "public"."priority" USING gist ("path");

ALTER TABLE "public"."priority" ENABLE ROW LEVEL SECURITY;

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
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "archived_at" timestamp with time zone,
    CONSTRAINT priority_user_unique UNIQUE (user_id, priority_id)
);

-- Index for user-based priority lookups in user_priority_base view
CREATE INDEX idx_priority_user_user_id ON "public"."priority_user" ("user_id")
WHERE
    archived_at IS NULL;

-- Optimized for user_priority_expanded GROUP BY operations
-- Supports efficient aggregation by user_id and priority_id with created_at
CREATE INDEX idx_priority_user_user_priority_archived ON "public"."priority_user" ("user_id", "priority_id", "created_at")
WHERE
    archived_at IS NULL;

ALTER TABLE "public"."priority_user" ENABLE ROW LEVEL SECURITY;

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
    -- Only create entry for new, top-level priorities.
    IF nlevel (NEW.path) = 1 THEN
        INSERT INTO public.priority_user (user_id, priority_id)
            VALUES (NEW.created_by, NEW.id);
    END IF;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql
SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION insert_priority_user () FROM anon;

REVOKE EXECUTE ON FUNCTION insert_priority_user () FROM authenticated;

CREATE TRIGGER priority_insert_trigger
    AFTER INSERT ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION insert_priority_user ();

-- Per-user priority settings
CREATE TABLE "public"."priority_settings" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    -- All fields added below must be handled in handle_user_priority_upsert
    "top_order" double precision,
    -- The fields below are inherited by sub-priorities
    -- If path is set, it overrides the sub-path below the root
    "path" ltree,
    "pomodoro" integer,
    "color" integer,
    CONSTRAINT priority_settings_unique UNIQUE (user_id, priority_id)
);

ALTER TABLE "public"."priority_settings" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_priority_settings_updated_at
    BEFORE INSERT OR UPDATE ON "public"."priority_settings"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER handle_priority_changes
    AFTER INSERT OR UPDATE ON public.priority
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_priority ();

