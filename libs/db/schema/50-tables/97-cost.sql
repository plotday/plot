CREATE TABLE "public"."cost" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL,
    "amount" numeric
);

ALTER TABLE "public"."cost" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_cost_updated_at
    BEFORE UPDATE ON "public"."cost"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
