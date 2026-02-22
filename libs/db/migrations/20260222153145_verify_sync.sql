-- Create "actor" function
CREATE FUNCTION "public"."actor" ("user"."activity") RETURNS SETOF "public"."actor" LANGUAGE sql STABLE AS $$
SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$$;
-- Create "actor" function
CREATE FUNCTION "public"."actor" ("public"."activity_x") RETURNS SETOF "public"."actor" LANGUAGE sql STABLE AS $$
SELECT
        actor.*
    FROM
        actor
    WHERE
        actor.id = $1.author_id
$$;
