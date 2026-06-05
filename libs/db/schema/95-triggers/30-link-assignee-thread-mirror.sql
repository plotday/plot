-- AFTER INSERT/UPDATE/DELETE on link → recompute affected threads' assignee.
-- Statement-level (bulk writes recompute each thread once). Separate triggers
-- because NEW TABLE / OLD TABLE references are fixed per operation.

CREATE OR REPLACE FUNCTION public.mirror_link_assignee_ins() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    PERFORM public.recompute_thread_assignee(
        ARRAY(SELECT DISTINCT thread_id FROM new_table WHERE thread_id IS NOT NULL));
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mirror_link_assignee_upd() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    PERFORM public.recompute_thread_assignee(ARRAY(
        SELECT DISTINCT thread_id FROM (
            SELECT thread_id FROM new_table
            UNION
            SELECT thread_id FROM old_table
        ) x WHERE thread_id IS NOT NULL));
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mirror_link_assignee_del() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    PERFORM public.recompute_thread_assignee(
        ARRAY(SELECT DISTINCT thread_id FROM old_table WHERE thread_id IS NOT NULL));
    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER link_assignee_mirror_ins
    AFTER INSERT ON link
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT EXECUTE FUNCTION public.mirror_link_assignee_ins();

CREATE OR REPLACE TRIGGER link_assignee_mirror_upd
    AFTER UPDATE ON link
    REFERENCING NEW TABLE AS new_table OLD TABLE AS old_table
    FOR EACH STATEMENT EXECUTE FUNCTION public.mirror_link_assignee_upd();

CREATE OR REPLACE TRIGGER link_assignee_mirror_del
    AFTER DELETE ON link
    REFERENCING OLD TABLE AS old_table
    FOR EACH STATEMENT EXECUTE FUNCTION public.mirror_link_assignee_del();
