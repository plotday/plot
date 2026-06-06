-- Create "file_thread_priority_on_topic_optout_change" function
CREATE FUNCTION "public"."file_thread_priority_on_topic_optout_change" () RETURNS trigger LANGUAGE plpgsql AS $$
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
-- Create trigger "file_thread_priority_on_topic_optout_change"
CREATE TRIGGER "file_thread_priority_on_topic_optout_change" AFTER DELETE OR INSERT ON "public"."topic_member_optout" FOR EACH ROW EXECUTE FUNCTION "public"."file_thread_priority_on_topic_optout_change"();
