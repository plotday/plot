CREATE TABLE "public"."priority" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "draft" boolean NOT NULL DEFAULT FALSE,
    "created_by" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "name" text NOT NULL,
    "path" ltree NOT NULL UNIQUE
);

ALTER TABLE "public"."priority" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_priority_updated_at
    BEFORE UPDATE ON "public"."priority"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_created_by
    BEFORE INSERT ON "public"."priority"
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

-- Only path roots get entries
CREATE TABLE "public"."priority_user" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    CONSTRAINT priority_user_unique UNIQUE (user_id, priority_id)
);

ALTER TABLE "public"."priority_user" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_priority_user_updated_at
    BEFORE UPDATE ON "public"."priority_user"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TABLE "public"."priority_settings" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    -- If set, overrides the path root. Only used for shared priorities.
    "path" ltree,
    "order" double precision NOT NULL,
    "pomodoro" integer NOT NULL DEFAULT 25 * 60,
    "color" integer NOT NULL DEFAULT 0,
    "is_default" boolean NOT NULL DEFAULT FALSE,
    CONSTRAINT user_priority_unique UNIQUE ("user_id", "priority_id")
);

CREATE UNIQUE INDEX ON public.priority_settings (user_id)
WHERE
    is_default = TRUE;

ALTER TABLE "public"."priority_settings" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_priority_settings_updated_at
    BEFORE UPDATE ON "public"."priority_settings"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE OR REPLACE FUNCTION insert_priority_user ()
    RETURNS TRIGGER
    AS $$
BEGIN
    IF nlevel (NEW.path) = 1 THEN
        INSERT INTO public.priority_user (created_at, updated_at, user_id, priority_id)
            VALUES (now(), now(), NEW.created_by, NEW.id);
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

