CREATE TABLE "public"."usage" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "twist_instance_id" uuid NOT NULL REFERENCES public.twist_instance ON DELETE CASCADE,
    "hour" timestamp with time zone NOT NULL,
    "cost_id" bigint NOT NULL REFERENCES public.cost ON DELETE CASCADE,
    "amount" integer NOT NULL,
    UNIQUE ("twist_instance_id", "hour", "cost_id"),
    CHECK ("hour" = DATE_TRUNC('hour', "hour"))
);

CREATE INDEX idx_usage_twist_instance_id ON "public"."usage" ("twist_instance_id");

CREATE TRIGGER set_usage_updated_at
    BEFORE INSERT OR UPDATE ON "public"."usage"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_usage_created_at
    BEFORE INSERT ON "public"."usage"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
