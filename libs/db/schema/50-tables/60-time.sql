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

CREATE TABLE "public"."time" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "activity_id" bigint REFERENCES activity ON DELETE CASCADE,
    "at" tstzrange NOT NULL CHECK (is_finite (at))
);

ALTER TABLE "public"."time" ENABLE ROW LEVEL SECURITY;

ALTER publication supabase_realtime
    ADD TABLE public."time";

CREATE INDEX time_at_idx ON "time" USING spgist (at);

