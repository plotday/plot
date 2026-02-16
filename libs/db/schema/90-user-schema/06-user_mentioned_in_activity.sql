-- Helper function to check if a user is mentioned in an activity's notes
CREATE OR REPLACE FUNCTION "user".mentioned_in_activity (user_id uuid, activity_id uuid)
    RETURNS boolean
    LANGUAGE sql
    STABLE
    AS $function$
    SELECT
        EXISTS (
            SELECT
                1
            FROM
                public.note
            WHERE
                note.activity_id = mentioned_in_activity.activity_id
                AND note.archived_at IS NULL
                AND mentioned_in_activity.user_id = ANY (note.mentions));
$function$;
