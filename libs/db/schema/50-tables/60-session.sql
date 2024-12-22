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
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "activity_id" uuid REFERENCES activity ON DELETE SET NULL,
    "at" tstzrange NOT NULL CHECK (is_finite (at)),
    "priority" smallint NOT NULL DEFAULT 0,
    "pomodoro" smallint CHECK (pomodoro IS NULL OR pomodoro > 0),
    "pomodoro_at" timestamp with time zone
);

ALTER TABLE "public"."session" ENABLE ROW LEVEL SECURITY;

ALTER publication supabase_realtime
    ADD TABLE public."session";

CREATE INDEX session_at_idx ON "session" USING spgist (at);

CREATE TRIGGER set_session_updated_at
    BEFORE UPDATE ON "public"."session"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

