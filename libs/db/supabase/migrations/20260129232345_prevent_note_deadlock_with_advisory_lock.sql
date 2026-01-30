SET ROLE "postgres";
SET check_function_bodies = false;
CREATE OR REPLACE FUNCTION public.update_activity_on_note_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
    -- On addition of a non-draft, non-archived note:
    -- Keep the activity read for the note creator if no one else has added notes
    -- since they last marked it read
    IF NEW.draft = FALSE AND NEW.archived_at IS NULL THEN
        -- Acquire advisory lock on this activity to serialize concurrent updates
        -- This prevents deadlocks when multiple notes are created simultaneously
        -- Lock is automatically released at transaction end
        PERFORM pg_advisory_xact_lock(hashtext(NEW.activity_id::text));

        -- Upsert activity_read for the note creator
        -- Only update if no other users have created notes since their last read_at
        -- Only track read status for actual users (not twists or contacts)
        INSERT INTO activity_read (user_id, activity_id, read_at)
        SELECT
            NEW.created_by,
            NEW.activity_id,
            NEW.created_at
        WHERE
            -- Only insert if created_by is an actual user from auth.users
            EXISTS (
                SELECT
                    1
                FROM
                    auth.users
                WHERE
                    id = NEW.created_by)
            AND NOT EXISTS (
                -- Check if any other user created notes since this user's last read_at
                SELECT
                    1
                FROM
                    note n
                LEFT JOIN activity_read ar ON ar.user_id = NEW.created_by
                    AND ar.activity_id = NEW.activity_id
            WHERE
                n.activity_id = NEW.activity_id
                AND n.created_by != NEW.created_by
                AND n.draft = FALSE
                AND n.archived_at IS NULL
                AND n.created_at > COALESCE(ar.read_at, '-infinity'::timestamp with time zone))
        ON CONFLICT (user_id,
            activity_id)
            DO UPDATE SET
                read_at = NEW.created_at,
                updated_at = now()
            WHERE
                -- Only update if still no other users have notes since current read_at
                NOT EXISTS (
                    SELECT
                        1
                    FROM
                        note n
                    WHERE
                        n.activity_id = NEW.activity_id
                        AND n.created_by != NEW.created_by
                        AND n.draft = FALSE
                        AND n.archived_at IS NULL
                        AND n.created_at > activity_read.read_at);
        -- Update activity's last_note_created_at and last_note_source_created_at when notes are inserted/deleted
        -- Note: note.updated_at changes do NOT trigger this
        -- Uses GREATEST() instead of MAX subquery since we only need to update if the new value exceeds the current
        -- Also update updated_by to the note's updated_by so webhook-originated notes appear in sync views
        UPDATE
            activity
        SET
            last_note_created_at = GREATEST (last_note_created_at, NEW.created_at),
            last_note_source_created_at = GREATEST (last_note_source_created_at, NEW.source_created_at),
            updated_by = NEW.updated_by
        WHERE
            id = NEW.activity_id
            AND (last_note_created_at IS NULL
                OR last_note_created_at < NEW.created_at
                OR last_note_source_created_at IS NULL
                OR last_note_source_created_at < NEW.source_created_at);
    END IF;
    RETURN COALESCE(NEW, OLD);
END;
$function$;
CREATE OR REPLACE TRIGGER set_activity_source_priority_root_trigger BEFORE INSERT OR UPDATE OF source, priority_id ON public.activity FOR EACH ROW EXECUTE FUNCTION public.set_activity_source_priority_root();
CREATE OR REPLACE TRIGGER update_activity_last_note_created_at_on_status_change AFTER UPDATE OF draft, archived_at ON public.note FOR EACH ROW WHEN (old.draft IS DISTINCT FROM new.draft OR old.archived_at IS DISTINCT FROM new.archived_at) EXECUTE FUNCTION public.update_activity_on_note_change();

ALTER VIEW "public"."user_note" SET ( security_invoker = TRUE);
ALTER VIEW "public"."note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_note_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_twist" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_x" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_create" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_note_update" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_twist_activity_tag_change" SET ( security_invoker = TRUE);
ALTER VIEW public.priority_member SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
