CREATE OR REPLACE FUNCTION is_week (p_week daterange)
    RETURNS boolean
    LANGUAGE 'plpgsql'
    IMMUTABLE
    AS $$
BEGIN
    RETURN p_week IS NULL
        OR EXTRACT(DOW FROM lower(p_week)) = 0
        AND upper(p_week) - lower(p_week) = 7;
END;
$$;

CREATE TABLE "public"."budget" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "activity_id" bigint REFERENCES activity ON DELETE CASCADE,
    "week" daterange CHECK (is_week (week)),
    "order" text,
    "budget" integer,
    CONSTRAINT budget_user_activity_week_unique UNIQUE NULLS NOT DISTINCT (user_id, activity_id, week)
);

ALTER TABLE "public"."budget" ENABLE ROW LEVEL SECURITY;

-- Define a computed relation for PostgREST joins
-- https://postgrest.org/en/stable/references/api/resource_embedding.html#computed-relationships
CREATE OR REPLACE FUNCTION public.budget (activity)
    RETURNS SETOF budget
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        *
    FROM
        budget
    WHERE
        activity_id = $1.id;
$function$;

