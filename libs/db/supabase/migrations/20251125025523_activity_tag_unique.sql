ALTER TABLE "public"."activity_tag"
    DROP CONSTRAINT "activity_tag_actor_id_activity_id_tag_id_key";

DROP INDEX IF EXISTS "public"."activity_tag_actor_id_activity_id_tag_id_key";

CREATE UNIQUE INDEX activity_tag_actor_id_activity_id_occurrence_tag_id_key ON public.activity_tag USING btree (actor_id, activity_id, occurrence, tag_id) NULLS NOT DISTINCT;

ALTER TABLE "public"."activity_tag"
    ADD CONSTRAINT "activity_tag_actor_id_activity_id_occurrence_tag_id_key" UNIQUE USING INDEX "activity_tag_actor_id_activity_id_occurrence_tag_id_key";

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_unread" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_twist" SET (security_invoker = TRUE);

