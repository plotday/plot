-- WARNING! This table is currently readable by all users.
-- WARNING! Changes will be needed if adding sensitive fields.
CREATE TABLE "public"."team" (
    "id" bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY NOT NULL,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "name" text NOT NULL,
    "billing_email" text
);

CREATE TRIGGER set_team_updated_at
    BEFORE INSERT OR UPDATE ON "public"."team"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();
