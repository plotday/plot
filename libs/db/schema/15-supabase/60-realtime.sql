CREATE SCHEMA IF NOT EXISTS "realtime";

CREATE OR REPLACE FUNCTION realtime.topic ()
    RETURNS text
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        'sync:' || auth.uid ()::text
$function$;

CREATE TABLE IF NOT EXISTS "realtime"."messages" (
    "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
    "topic" text NOT NULL,
    "payload" jsonb NOT NULL,
    "created_at" timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY ("id")
);

