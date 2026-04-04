-- Helper function to check if a user is mentioned in a thread's notes.
-- Mentions store contact IDs (not user IDs), so we look up the user's
-- primary contact ID and check that.
CREATE OR REPLACE FUNCTION "user".mentioned_in_thread (user_id uuid, thread_id uuid)
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
                note.thread_id = mentioned_in_thread.thread_id
                AND note.archived_at IS NULL
                AND "user".user_contact_id(mentioned_in_thread.user_id) = ANY (note.mentions));
$function$;
