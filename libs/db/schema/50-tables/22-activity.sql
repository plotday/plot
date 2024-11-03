CREATE TABLE "public"."activity" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES auth.users ON DELETE SET NULL,
    "name" text NOT NULL,
    "path" ltree NOT NULL UNIQUE
);

ALTER TABLE "public"."activity" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_activity_modified_at
    BEFORE UPDATE ON "public"."activity"
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_activity_created_by
    BEFORE INSERT ON "public"."activity"
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

CREATE TABLE "public"."activity_user" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "activity_id" uuid NOT NULL REFERENCES public.activity ON DELETE CASCADE,
    "path" ltree,
    CONSTRAINT activity_user_user_path_unique UNIQUE (user_id, path)
);

ALTER TABLE "public"."activity_user" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_activity_user_modified_at
    BEFORE UPDATE ON "public"."activity_user"
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TABLE "public"."activity_settings" (
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "activity_id" uuid NOT NULL REFERENCES public.activity ON DELETE CASCADE,
    "order" double precision NOT NULL,
    "pomodoro" integer NOT NULL DEFAULT 25 * 60,
    CONSTRAINT user_activity_unique UNIQUE ("user_id", "activity_id")
);

ALTER TABLE "public"."activity_settings" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_activity_settings_modified_at
    BEFORE UPDATE ON "public"."activity_settings"
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE OR REPLACE FUNCTION insert_activity_user ()
    RETURNS TRIGGER
    AS $$
BEGIN
    IF nlevel (NEW.path) = 1 THEN
        INSERT INTO public.activity_user (created_at, modified_at, user_id, activity_id)
            VALUES (now(), now(), NEW.created_by, NEW.id);
    END IF;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql
SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION insert_activity_user () FROM anon;

REVOKE EXECUTE ON FUNCTION insert_activity_user () FROM authenticated;

CREATE TRIGGER activity_insert_trigger
    AFTER INSERT ON public.activity
    FOR EACH ROW
    EXECUTE FUNCTION insert_activity_user ();

