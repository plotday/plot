-- Bump topic.seq when membership/governance child rows change, so /sync/topics
-- (paginated on topic.seq) re-pulls the row and its computed user.topic columns.
-- Statement-level so a bulk write bumps each affected topic once. Mirrors the
-- group_member seq-bump in 24-group_auto_maintain.sql.
CREATE OR REPLACE FUNCTION public.bump_topic_seq_from_new_table ()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "topic" SET updated_at = now()
    WHERE id IN (SELECT DISTINCT topic_id FROM new_table);
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.bump_topic_seq_from_old_table ()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE "topic" SET updated_at = now()
    WHERE id IN (SELECT DISTINCT topic_id FROM old_table);
    RETURN NULL;
END;
$$;

CREATE TRIGGER bump_topic_seq_on_contact_insert AFTER INSERT ON public.topic_contact
    REFERENCING NEW TABLE AS new_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_new_table ();
CREATE TRIGGER bump_topic_seq_on_contact_delete AFTER DELETE ON public.topic_contact
    REFERENCING OLD TABLE AS old_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_old_table ();
CREATE TRIGGER bump_topic_seq_on_group_insert AFTER INSERT ON public.topic_group
    REFERENCING NEW TABLE AS new_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_new_table ();
CREATE TRIGGER bump_topic_seq_on_group_delete AFTER DELETE ON public.topic_group
    REFERENCING OLD TABLE AS old_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_old_table ();
CREATE TRIGGER bump_topic_seq_on_admin_insert AFTER INSERT ON public.topic_admin
    REFERENCING NEW TABLE AS new_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_new_table ();
CREATE TRIGGER bump_topic_seq_on_admin_delete AFTER DELETE ON public.topic_admin
    REFERENCING OLD TABLE AS old_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_old_table ();
CREATE TRIGGER bump_topic_seq_on_optout_insert AFTER INSERT ON public.topic_member_optout
    REFERENCING NEW TABLE AS new_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_new_table ();
CREATE TRIGGER bump_topic_seq_on_optout_delete AFTER DELETE ON public.topic_member_optout
    REFERENCING OLD TABLE AS old_table FOR EACH STATEMENT
    EXECUTE FUNCTION public.bump_topic_seq_from_old_table ();
