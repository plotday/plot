CREATE TABLE "public"."token" (
    "id" uuid NOT NULL DEFAULT gen_random_uuid (),
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "user_id" uuid NOT NULL,
    "token" text NOT NULL,
    "name" text,
    "last_used_at" timestamp with time zone
);

ALTER TABLE "public"."token" ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX token_pkey ON public.token USING btree (id);

CREATE UNIQUE INDEX token_token_key ON public.token USING btree (token);

ALTER TABLE "public"."token"
    ADD CONSTRAINT "token_pkey" PRIMARY KEY USING INDEX "token_pkey";

ALTER TABLE "public"."token"
    ADD CONSTRAINT "token_token_key" UNIQUE USING INDEX "token_token_key";

ALTER TABLE "public"."token"
    ADD CONSTRAINT "token_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."token" validate CONSTRAINT "token_user_id_fkey";

CREATE POLICY "Users can create their own tokens" ON "public"."token" AS permissive
    FOR INSERT TO public
        WITH CHECK ((auth.uid () = user_id));

CREATE POLICY "Users can delete their own tokens" ON "public"."token" AS permissive
    FOR DELETE TO public
        USING ((auth.uid () = user_id));

CREATE POLICY "Users can update their own tokens" ON "public"."token" AS permissive
    FOR UPDATE TO public
        USING ((auth.uid () = user_id))
        WITH CHECK ((auth.uid () = user_id));

CREATE POLICY "Users can view their own tokens" ON "public"."token" AS permissive
    FOR SELECT TO public
        USING ((auth.uid () = user_id));

CREATE TRIGGER set_token_updated_at
    BEFORE UPDATE ON public.token
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_settings_inherited" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_agent" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
