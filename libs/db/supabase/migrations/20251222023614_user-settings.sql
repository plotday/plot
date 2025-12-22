CREATE TABLE "public"."user_settings" (
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "user_id" uuid NOT NULL,
    "enter_behavior" text
);

ALTER TABLE "public"."user_settings" ENABLE ROW LEVEL SECURITY;

CREATE INDEX idx_user_settings_user_id ON public.user_settings USING btree (user_id);

CREATE UNIQUE INDEX user_settings_pkey ON public.user_settings USING btree (user_id);

ALTER TABLE "public"."user_settings"
    ADD CONSTRAINT "user_settings_pkey" PRIMARY KEY USING INDEX "user_settings_pkey";

ALTER TABLE "public"."user_settings"
    ADD CONSTRAINT "user_settings_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."user_settings" validate CONSTRAINT "user_settings_user_id_fkey";

CREATE POLICY "Users can read/write their settings" ON "public"."user_settings" AS permissive
    FOR ALL TO authenticated
        USING ((user_id = auth.uid ()));

CREATE TRIGGER set_user_settings_updated_at
    BEFORE UPDATE ON public.user_settings
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

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
ALTER VIEW "public"."user_priority_unread" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_expanded" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
