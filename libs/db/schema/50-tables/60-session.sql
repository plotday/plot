CREATE OR REPLACE FUNCTION public.is_finite (test tstzrange)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    IMMUTABLE
    AS $$
BEGIN
    RETURN NOT (lower_inf(test)
        OR upper_inf(test));
END;
$$;

CREATE TABLE "public"."session" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "priority_id" uuid REFERENCES priority ON DELETE SET NULL,
    "at" tstzrange NOT NULL CHECK (is_finite (at)),
    "precedence" smallint NOT NULL DEFAULT 0,
    "pomodoro" smallint CHECK (pomodoro IS NULL OR pomodoro > 0),
    "pomodoro_at" timestamp with time zone,
    "updated_by" integer NOT NULL DEFAULT 0
);

ALTER TABLE "public"."session" ENABLE ROW LEVEL SECURITY;

CREATE INDEX session_at_idx ON "session" USING spgist (at);

CREATE TRIGGER set_session_updated_at
    BEFORE INSERT OR UPDATE ON "public"."session"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_session_created_at
    BEFORE INSERT ON "public"."session"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

