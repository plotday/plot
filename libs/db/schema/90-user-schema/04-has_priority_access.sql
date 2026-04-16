-- Check if a user has access to a priority (user schema wrapper)
-- Used by update_thread_tags, update_note_tags, and API code
CREATE OR REPLACE FUNCTION "user".has_priority_access (user_id uuid, priority_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SET search_path TO 'public'
    AS $function$
    SELECT
        public.user_has_priority_access (user_id, priority_id)
$function$;
