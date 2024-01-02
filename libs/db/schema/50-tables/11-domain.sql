CREATE OR REPLACE FUNCTION is_lower (text)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    IMMUTABLE
    AS $$
BEGIN
    RETURN $1 = lower($1);
END;
$$;

CREATE TABLE "public"."domain" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "domain" text UNIQUE NOT NULL CHECK (is_lower ("domain")),
    "organization_id" bigint REFERENCES organization ON DELETE SET NULL
);

ALTER TABLE "public"."domain" ENABLE ROW LEVEL SECURITY;

