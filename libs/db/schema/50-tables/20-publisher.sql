CREATE TABLE "public"."publisher" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "created_by" uuid NOT NULL REFERENCES public."user" ("id") ON DELETE RESTRICT,
    "name" text NOT NULL,
    "email" text,
    "url" text
);

CREATE UNIQUE INDEX idx_publisher_name_lower ON "public"."publisher" (lower("name"));

CREATE INDEX idx_publisher_created_by ON "public"."publisher" ("created_by");

CREATE TRIGGER set_publisher_updated_at
    BEFORE INSERT OR UPDATE ON "public"."publisher"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_publisher_created_at
    BEFORE INSERT ON "public"."publisher"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();
