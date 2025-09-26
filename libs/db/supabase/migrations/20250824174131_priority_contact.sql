DROP POLICY "Users can view their contact" ON "public"."contact";

CREATE TABLE "public"."priority_contact" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "deleted_at" timestamp with time zone,
    "priority_id" uuid NOT NULL,
    "contact_id" bigint NOT NULL
);

ALTER TABLE "public"."priority_contact" ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX priority_contact_pkey ON public.priority_contact USING btree (id);

CREATE UNIQUE INDEX priority_contact_unique ON public.priority_contact USING btree (priority_id, contact_id);

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_pkey" PRIMARY KEY USING INDEX "priority_contact_pkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_contact_id_fkey" FOREIGN KEY (contact_id) REFERENCES contact (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_contact" validate CONSTRAINT "priority_contact_contact_id_fkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_priority_id_fkey" FOREIGN KEY (priority_id) REFERENCES priority (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."priority_contact" validate CONSTRAINT "priority_contact_priority_id_fkey";

ALTER TABLE "public"."priority_contact"
    ADD CONSTRAINT "priority_contact_unique" UNIQUE USING INDEX "priority_contact_unique";

CREATE POLICY "Users can view contacts linked to their priorities" ON "public"."contact" AS permissive
    FOR SELECT TO authenticated
        USING ((EXISTS (
            SELECT
                1
            FROM
                priority_contact pc
            WHERE ((pc.contact_id = contact.id) AND (pc.deleted_at IS NULL) AND user_has_priority_access (auth.uid (), pc.priority_id)))));

CREATE POLICY "Users can access priority contacts for their priorities" ON "public"."priority_contact" AS permissive
    FOR ALL TO authenticated
        USING (user_has_priority_access (auth.uid (), priority_id));

ALTER VIEW "public"."activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."activity_children" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_exception" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_activity_tags" SET ( security_invoker = TRUE);
ALTER VIEW "admin"."invitation" SET ( security_invoker = FALSE);
ALTER VIEW "public"."priority_tags" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child" SET ( security_invoker = TRUE);
ALTER VIEW "public"."user_priority" SET ( security_invoker = TRUE);
ALTER VIEW "public"."priority_child_agent" SET ( security_invoker = TRUE);
ALTER VIEW "public"."actor" SET ( security_invoker = TRUE);
