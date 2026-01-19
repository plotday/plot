CREATE TABLE "public"."priority_twist_sync" (
    "priority_twist_id" uuid NOT NULL,
    "entity" text NOT NULL,
    "last_update_at" timestamp with time zone NOT NULL,
    "last_sync_at" timestamp with time zone NOT NULL DEFAULT '1970-01-01 00:00:00+00' ::timestamp with time zone
);

ALTER TABLE "public"."priority_twist_sync" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."user_sync" (
    "user_id" uuid NOT NULL,
    "entity" text NOT NULL,
    "last_update_at" timestamp with time zone NOT NULL,
    "last_sync_at" timestamp with time zone NOT NULL DEFAULT '1970-01-01 00:00:00+00' ::timestamp with time zone
);

ALTER TABLE "public"."user_sync" ENABLE ROW LEVEL SECURITY;

CREATE INDEX idx_priority_twist_sync_pending ON public.priority_twist_sync USING btree (priority_twist_id)
WHERE (last_update_at > last_sync_at);

CREATE INDEX idx_user_sync_pending ON public.user_sync USING btree (user_id)
WHERE (last_update_at > last_sync_at);

CREATE UNIQUE INDEX priority_twist_sync_pkey ON public.priority_twist_sync USING btree (priority_twist_id, entity);

CREATE UNIQUE INDEX user_sync_pkey ON public.user_sync USING btree (user_id, entity);

ALTER TABLE "public"."priority_twist_sync"
    ADD CONSTRAINT "priority_twist_sync_pkey" PRIMARY KEY USING INDEX "priority_twist_sync_pkey";

ALTER TABLE "public"."user_sync"
    ADD CONSTRAINT "user_sync_pkey" PRIMARY KEY USING INDEX "user_sync_pkey";

ALTER TABLE "public"."priority_twist_sync"
    ADD CONSTRAINT "priority_twist_sync_priority_twist_id_fkey" FOREIGN KEY (priority_twist_id) REFERENCES priority_twist (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_twist_sync" validate CONSTRAINT "priority_twist_sync_priority_twist_id_fkey";

ALTER TABLE "public"."user_sync"
    ADD CONSTRAINT "user_sync_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."user_sync" validate CONSTRAINT "user_sync_user_id_fkey";

CREATE POLICY "service_role_all" ON "public"."priority_twist_sync" AS permissive
    FOR ALL TO service_role
        USING (TRUE)
        WITH CHECK (TRUE);

CREATE POLICY "service_role_all" ON "public"."user_sync" AS permissive
    FOR ALL TO service_role
        USING (TRUE)
        WITH CHECK (TRUE);

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
ALTER VIEW "public"."user_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority_actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_twist" SET ( security_invoker = TRUE);
