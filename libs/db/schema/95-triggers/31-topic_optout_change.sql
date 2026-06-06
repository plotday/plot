-- Leaving a topic (INSERT into topic_member_optout) revokes the user's access
-- to the topic's threads when no other path remains; rejoining (DELETE) grants
-- it back. Reuses the grant/revoke helpers from 30-topic_member_change.sql.
CREATE OR REPLACE FUNCTION public.file_thread_priority_on_topic_optout_change ()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM public.revoke_topic_threads_from_user(NEW.topic_id, NEW.user_id);
        RETURN NEW;
    ELSE
        PERFORM public.grant_topic_threads_to_user(OLD.topic_id, OLD.user_id);
        RETURN OLD;
    END IF;
END;
$$;

CREATE TRIGGER file_thread_priority_on_topic_optout_change
    AFTER INSERT OR DELETE ON public.topic_member_optout
    FOR EACH ROW EXECUTE FUNCTION public.file_thread_priority_on_topic_optout_change ();
