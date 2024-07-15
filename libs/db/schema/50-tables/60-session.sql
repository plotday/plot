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
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "modified_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "context_id" bigint REFERENCES context ON DELETE SET NULL,
    "event_id" bigint REFERENCES event ON DELETE SET NULL,
    "at" tstzrange NOT NULL CHECK (is_finite (at)),
    "paused" interval NOT NULL DEFAULT '00:00:00' ::interval CHECK (paused >= '00:00:00'::interval),
    "pomodoro_start" timestamptz CHECK (pomodoro_start >= LOWER(at) AND pomodoro_start <= UPPER(at)),
    "pomodoro_length" interval CHECK (pomodoro_length IS NULL OR pomodoro_length > '00:00:00'::interval),
    EXCLUDE USING gist (user_id WITH =, (EXTRACT(epoch FROM (upper(at) - lower(at))) > 60 * 5
) WITH =, at WITH &&)
);

ALTER TABLE "public"."session" ENABLE ROW LEVEL SECURITY;

ALTER publication supabase_realtime
    ADD TABLE public."session";

CREATE INDEX session_at_idx ON "session" USING spgist (at);

CREATE TRIGGER set_session_modified_at
    BEFORE UPDATE ON "public"."session"
    FOR EACH ROW
    EXECUTE FUNCTION update_modified_at ();

