CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;

CREATE EXTENSION IF NOT EXISTS pg_tle;

DROP EXTENSION IF EXISTS "supabase-dbdev";

SELECT
    pgtle.uninstall_extension_if_exists ('supabase-dbdev');

SELECT
    pgtle.install_extension ('supabase-dbdev', resp.contents ->> 'version', 'PostgreSQL package manager', resp.contents ->> 'sql')
FROM
    http (('GET', 'https://api.database.dev/rest/v1/' || 'package_versions?select=sql,version' || '&package_name=eq.supabase-dbdev' || '&order=version.desc' || '&limit=1', ARRAY[('apiKey', 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhtdXB0cHBsZnZpaWZyYndtbXR2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE2ODAxMDczNzIsImV4cCI6MTk5NTY4MzM3Mn0.z2CN0mvO2No8wSi46Gw59DFGCTJrzM0AQKsu_5k134s')::http_header], NULL, NULL)) x,
    LATERAL (
        SELECT
            ((row_to_json(x) -> 'content') #>> '{}')::json -> 0) resp (contents);

CREATE EXTENSION "supabase-dbdev";

SELECT
    dbdev.install ('supabase-dbdev');

DROP EXTENSION IF EXISTS "supabase-dbdev";

CREATE EXTENSION "supabase-dbdev";

SELECT
    *
FROM
    dbdev.install ('kiwicopple-pg_idkit');

CREATE EXTENSION "kiwicopple-pg_idkit" WITH SCHEMA extensions;

ALTER TABLE "public"."context"
    ALTER COLUMN "id" SET DEFAULT gen_random_uuid_v7 ();

ALTER TABLE "public"."event"
    ALTER COLUMN "id" SET DEFAULT gen_random_uuid_v7 ();

ALTER TABLE "public"."note"
    ALTER COLUMN "id" SET DEFAULT gen_random_uuid_v7 ();

CREATE OR REPLACE FUNCTION public.handle_context_x_insert ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
DECLARE
    context_id uuid;
BEGIN
    context_id := NEW.id;
    IF context_id IS NULL THEN
        context_id := gen_random_uuid_v7 ();
    END IF;
    INSERT INTO context (id, name, path, created_by)
        VALUES (context_id, NEW.name, NEW.path, auth.uid ());
    IF NEW.order IS NOT NULL OR NEW.pomodoro IS NOT NULL THEN
        INSERT INTO context_settings (user_id, context_id, "order", pomodoro)
            VALUES (auth.uid (), context_id, NEW.order, COALESCE(NEW.pomodoro, 25));
    END IF;
    RETURN NEW;
END;
$function$;

