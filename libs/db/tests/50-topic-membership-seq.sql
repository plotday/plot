-- topic cluster exists; membership writes bump topic.seq so /sync/topics
-- re-pulls the row (mirrors the group_member seq-bump invariant).
--
-- Within one transaction pg_current_xact_id() and now() are constant, so we
-- can't observe seq advancing *between* two membership writes. Instead, before
-- each write we force topic.seq back to '1' (briefly disabling the BEFORE
-- trigger that would otherwise overwrite an explicit seq), then assert the
-- AFTER-STATEMENT bump trigger advanced it to the current xact id. Covering an
-- insert (new_table bump fn), a cross-table topic_group insert, and a delete
-- (old_table bump fn) exercises both bump functions.
BEGIN;
SET LOCAL search_path = public, extensions;
SELECT plan(8);

SELECT has_table('public'::name, 'topic'::name, 'topic table exists');
SELECT has_table('public'::name, 'topic_contact'::name, 'topic_contact table exists');
SELECT has_table('public'::name, 'topic_group'::name, 'topic_group table exists');
SELECT has_table('public'::name, 'topic_admin'::name, 'topic_admin table exists');
SELECT has_table('public'::name, 'topic_member_optout'::name, 'topic_member_optout table exists');

DO $$
DECLARE
    v_user uuid := gen_random_uuid();
    v_contact uuid;
    v_group uuid := gen_random_uuid();
    v_topic uuid := gen_random_uuid();
BEGIN
    INSERT INTO "public"."user" (id, email) VALUES (v_user, 'topic50@test.local');
    v_contact := public.upsert_user_contact(v_user, 'topic50@test.local', 'T50', NULL);
    INSERT INTO public."group" (id, name, type, created_by) VALUES (v_group, 'G50', 'public', v_user);
    INSERT INTO public.topic (id, name, created_by) VALUES (v_topic, 'Topic 50', v_user);

    CREATE TEMP TABLE _seq50 (label text, bumped boolean);

    -- (a) topic_contact insert → new_table bump fn
    ALTER TABLE public.topic DISABLE TRIGGER set_topic_updated_at;
    UPDATE public.topic SET seq = '1'::xid8 WHERE id = v_topic;
    ALTER TABLE public.topic ENABLE TRIGGER set_topic_updated_at;
    INSERT INTO public.topic_contact (topic_id, contact_id) VALUES (v_topic, v_contact);
    INSERT INTO _seq50 SELECT 'contact insert', seq <> '1'::xid8 FROM public.topic WHERE id = v_topic;

    -- (b) topic_group insert → cross-table new_table bump fn
    ALTER TABLE public.topic DISABLE TRIGGER set_topic_updated_at;
    UPDATE public.topic SET seq = '1'::xid8 WHERE id = v_topic;
    ALTER TABLE public.topic ENABLE TRIGGER set_topic_updated_at;
    INSERT INTO public.topic_group (topic_id, group_id) VALUES (v_topic, v_group);
    INSERT INTO _seq50 SELECT 'group insert', seq <> '1'::xid8 FROM public.topic WHERE id = v_topic;

    -- (c) topic_contact delete → old_table bump fn
    ALTER TABLE public.topic DISABLE TRIGGER set_topic_updated_at;
    UPDATE public.topic SET seq = '1'::xid8 WHERE id = v_topic;
    ALTER TABLE public.topic ENABLE TRIGGER set_topic_updated_at;
    DELETE FROM public.topic_contact WHERE topic_id = v_topic AND contact_id = v_contact;
    INSERT INTO _seq50 SELECT 'contact delete', seq <> '1'::xid8 FROM public.topic WHERE id = v_topic;
END $$;

SELECT ok((SELECT bumped FROM _seq50 WHERE label='contact insert'), 'topic_contact insert bumps topic.seq (new_table fn)');
SELECT ok((SELECT bumped FROM _seq50 WHERE label='group insert'), 'topic_group insert bumps topic.seq (cross-table)');
SELECT ok((SELECT bumped FROM _seq50 WHERE label='contact delete'), 'topic_contact delete bumps topic.seq (old_table fn)');

SELECT * FROM finish();
ROLLBACK;
