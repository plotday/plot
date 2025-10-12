CREATE TABLE "public"."publisher" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL,
    "email" text,
    "url" text
);

ALTER TABLE "public"."publisher" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_publisher_updated_at
    BEFORE UPDATE ON "public"."publisher"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

