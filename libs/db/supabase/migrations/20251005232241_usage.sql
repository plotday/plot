CREATE TABLE "public"."cost" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "type" text UNIQUE NOT NULL,
    "amount" numeric
);

ALTER TABLE "public"."cost" ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."usage" (
    "id" bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "priority_agent_id" uuid NOT NULL,
    "hour" timestamp with time zone NOT NULL,
    "cost_id" bigint NOT NULL,
    "amount" integer NOT NULL
);

ALTER TABLE "public"."usage" ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX cost_pkey ON public.cost USING btree (id);

CREATE INDEX idx_usage_priority_agent_id ON public.usage USING btree (priority_agent_id);

CREATE UNIQUE INDEX usage_pkey ON public.usage USING btree (id);

ALTER TABLE "public"."cost"
    ADD CONSTRAINT "cost_pkey" PRIMARY KEY USING INDEX "cost_pkey";

ALTER TABLE "public"."usage"
    ADD CONSTRAINT "usage_pkey" PRIMARY KEY USING INDEX "usage_pkey";

ALTER TABLE "public"."usage"
    ADD CONSTRAINT "usage_cost_id_fkey" FOREIGN KEY (cost_id) REFERENCES COST (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."usage" validate CONSTRAINT "usage_cost_id_fkey";

ALTER TABLE "public"."usage"
    ADD CONSTRAINT "usage_priority_agent_id_fkey" FOREIGN KEY (priority_agent_id) REFERENCES priority_agent (id) ON DELETE CASCADE NOT valid;

ALTER TABLE "public"."usage" validate CONSTRAINT "usage_priority_agent_id_fkey";

CREATE TRIGGER set_cost_updated_at
    BEFORE UPDATE ON public.cost
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_usage_updated_at
    BEFORE UPDATE ON public.usage
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

ALTER VIEW "public"."activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."activity_children" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_exception" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_activity_tags" SET (security_invoker = TRUE);

ALTER VIEW "admin"."invitation" SET (security_invoker = FALSE);

ALTER VIEW "public"."priority_tags" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_settings_inherited" SET (security_invoker = TRUE);

ALTER VIEW "public"."user_priority" SET (security_invoker = TRUE);

ALTER VIEW "public"."priority_child_agent" SET (security_invoker = TRUE);

ALTER VIEW "public"."actor" SET (security_invoker = TRUE);

