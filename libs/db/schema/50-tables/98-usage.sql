CREATE TABLE "public"."usage" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "priority_twist_id" uuid NOT NULL REFERENCES public.priority_twist ON DELETE CASCADE,
    "hour" timestamp with time zone NOT NULL,
    "cost_id" bigint NOT NULL REFERENCES public.cost ON DELETE CASCADE,
    "amount" integer NOT NULL,
    UNIQUE ("priority_twist_id", "hour", "cost_id"),
    CHECK ("hour" = DATE_TRUNC('hour', "hour"))
);

CREATE INDEX idx_usage_priority_twist_id ON "public"."usage" ("priority_twist_id");

ALTER TABLE "public"."usage" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_usage_updated_at
    BEFORE UPDATE ON "public"."usage"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
