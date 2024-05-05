CREATE TYPE "public"."budget_type" AS ENUM (
    'default',
    'balance',
    'exception'
);

CREATE TABLE "public"."priority" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "context_id" bigint REFERENCES context ON DELETE CASCADE,
    "week" daterange NOT NULL CHECK (is_week (week)),
    "order" text,
    "budget" integer,
    "type" budget_type NOT NULL DEFAULT 'default' ::budget_type,
    CONSTRAINT priority_user_context_week_unique UNIQUE NULLS NOT DISTINCT (user_id, context_id, week)
);

ALTER TABLE "public"."priority" ENABLE ROW LEVEL SECURITY;

-- Define a computed relation for PostgREST joins
-- https://postgrest.org/en/stable/references/api/resource_embedding.html#computed-relationships
CREATE OR REPLACE FUNCTION public.priority (context)
    RETURNS SETOF priority
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        *
    FROM
        priority
    WHERE
        context_id = $1.id;
$function$;

