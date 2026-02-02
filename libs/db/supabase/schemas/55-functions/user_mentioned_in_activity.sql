-- Helper function to check if a user is mentioned in an activity's notes
-- SECURITY DEFINER to bypass RLS and avoid infinite recursion
CREATE OR REPLACE FUNCTION public.user_mentioned_in_activity (user_id uuid, activity_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    SECURITY DEFINER
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.note
            WHERE
                note.activity_id = user_mentioned_in_activity.activity_id
                AND note.archived_at IS NULL
                AND user_mentioned_in_activity.user_id = ANY (note.mentions));
$function$;
