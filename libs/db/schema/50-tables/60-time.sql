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

CREATE TYPE "public"."time_status" AS enum (
    'started',
    'paused',
    'skipped',
    'stopped'
);

CREATE TABLE "public"."time" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "activity_id" bigint REFERENCES activity ON DELETE SET NULL,
    "at" tstzrange NOT NULL CHECK (is_finite (at)),
    "status" time_status NOT NULL DEFAULT 'started',
    "event_id" bigint REFERENCES event ON DELETE SET NULL,
    "series_id" bigint REFERENCES "time" ON DELETE SET NULL,
    EXCLUDE USING gist (user_id WITH =, at WITH &&)
);

ALTER TABLE "public"."time" ENABLE ROW LEVEL SECURITY;

ALTER publication supabase_realtime
    ADD TABLE public."time";

CREATE INDEX time_at_idx ON "time" USING spgist (at);

