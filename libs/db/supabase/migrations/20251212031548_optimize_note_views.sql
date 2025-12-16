CREATE INDEX idx_activity_archived ON public.activity USING btree (archived_at)
WHERE (archived_at IS NULL);

CREATE INDEX idx_activity_priority_archived ON public.activity USING btree (priority_id, archived_at);

CREATE INDEX idx_note_activity_archived ON public.note USING btree (activity_id, archived_at);

CREATE INDEX idx_note_author_activity ON public.note USING btree (activity_id, author_id)
WHERE (archived_at IS NULL);

CREATE INDEX idx_note_mentions ON public.note USING gin (mentions)
WHERE ((mentions IS NOT NULL) AND (archived_at IS NULL));

CREATE INDEX idx_note_tag_note_id_full ON public.note_tag USING btree (note_id);

CREATE INDEX idx_priority_user_user_id ON public.priority_user USING btree (user_id)
WHERE (archived_at IS NULL);

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
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_base" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
