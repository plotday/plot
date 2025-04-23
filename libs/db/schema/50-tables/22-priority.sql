CREATE TABLE "public"."priority" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "created_by" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "name" text NOT NULL,
    "path" ltree NOT NULL UNIQUE,
    "draft" boolean NOT NULL DEFAULT FALSE,
    "private" boolean NOT NULL DEFAULT FALSE,
    "pinned" boolean NOT NULL DEFAULT FALSE,
    "do_at" timestamp with time zone,
    "done_at" timestamp with time zone,
    "order" double precision NOT NULL DEFAULT public.order_first (),
    "ordered_at" timestamp with time zone NOT NULL DEFAULT now(),
    "note" text
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

CREATE TABLE "public"."priority_user" (
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "order" double precision NOT NULL DEFAULT public.order_first (),
    -- an override if set; intended for shared roots
    "path" ltree,
    "pomodoro" integer,
    "color" integer,
    "is_default" boolean,
    CONSTRAINT priority_user_unique UNIQUE (user_id, priority_id)
);

ALTER TABLE "public"."priority_user" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_priority_user_updated_at
    BEFORE UPDATE ON "public"."priority_user"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE UNIQUE INDEX ON public.priority_user (user_id)
WHERE
    is_default = TRUE;

CREATE OR REPLACE FUNCTION insert_priority_user ()
    RETURNS TRIGGER
    AS $$
BEGIN
    -- Only create entry for new, top-level priorities.
    IF extensions.nlevel (NEW.path) = 1 THEN
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

