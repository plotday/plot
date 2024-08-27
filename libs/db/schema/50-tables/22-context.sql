CREATE TABLE "public"."context" (
    "id" uuid PRIMARY KEY DEFAULT uuid_generate_v4 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES auth.users ON DELETE SET NULL,
    "name" text NOT NULL,
    "path" ltree NOT NULL UNIQUE
);

ALTER TABLE "public"."context" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_context_modified_at
    BEFORE UPDATE ON "public"."context"
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TRIGGER set_context_created_by
    BEFORE INSERT ON "public"."context"
    FOR EACH ROW
    EXECUTE FUNCTION update_created_by ();

CREATE TABLE "public"."context_user" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "context_id" uuid NOT NULL REFERENCES public.context ON DELETE CASCADE,
    "path" ltree,
    CONSTRAINT context_user_user_path_unique UNIQUE (user_id, path)
);

ALTER TABLE "public"."context_user" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_context_user_modified_at
    BEFORE UPDATE ON "public"."context_user"
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE TABLE "public"."context_settings" (
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "context_id" uuid NOT NULL REFERENCES public.context ON DELETE CASCADE,
    "order" double precision NOT NULL,
    "pomodoro" integer NOT NULL DEFAULT 25,
    CONSTRAINT user_context_unique UNIQUE ("user_id", "context_id")
);

ALTER TABLE "public"."context_settings" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_context_settings_modified_at
    BEFORE UPDATE ON "public"."context_settings"
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

CREATE OR REPLACE FUNCTION insert_context_user ()
    RETURNS TRIGGER
    AS $$
BEGIN
    IF nlevel (NEW.path) = 1 THEN
        INSERT INTO public.context_user (created_at, modified_at, user_id, context_id)
            VALUES (now(), now(), NEW.created_by, NEW.id);
    END IF;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql
SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION insert_context_user () FROM anon;

REVOKE EXECUTE ON FUNCTION insert_context_user () FROM authenticated;

CREATE TRIGGER context_insert_trigger
    AFTER INSERT ON public.context
    FOR EACH ROW
    EXECUTE FUNCTION insert_context_user ();

