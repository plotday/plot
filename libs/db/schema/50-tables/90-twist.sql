-- All twists start in the 'personal' environment, which is the development environment.
-- They can be promoted to 'private' for private use, then to 'review'.
-- Only Plot can promot from 'review' to 'public'.
CREATE TYPE twist_environment AS ENUM (
    'personal',
    'private',
    'review',
    'public'
);

CREATE TABLE "public"."twist_admin" (
    "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "twist_package_id" uuid NOT NULL DEFAULT uuidv7 (),
    "user_id" uuid REFERENCES public."user" ON DELETE CASCADE,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "publisher_id" bigint REFERENCES public.publisher ON DELETE CASCADE,
    "priority_id" uuid REFERENCES public.priority ON DELETE CASCADE,
    "auto_approve" boolean NOT NULL DEFAULT FALSE,
    CONSTRAINT "twist_admin_ownership_check" CHECK (
        (publisher_id IS NOT NULL AND user_id IS NULL)
        OR
        (publisher_id IS NULL AND user_id IS NOT NULL)
    ),
    CONSTRAINT "twist_admin_package_user_unique" UNIQUE NULLS NOT DISTINCT ("twist_package_id", "user_id")
);

CREATE TRIGGER set_twist_admin_updated_at
    BEFORE INSERT OR UPDATE ON "public"."twist_admin"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_twist_admin_created_at
    BEFORE INSERT ON "public"."twist_admin"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

-- Indexes for foreign key performance
CREATE INDEX idx_twist_admin_user_id ON "public"."twist_admin" (user_id);

CREATE INDEX idx_twist_admin_publisher_id ON "public"."twist_admin" (publisher_id);

CREATE INDEX idx_twist_admin_priority_id ON "public"."twist_admin" (priority_id);

CREATE TABLE "public"."twist" (
    "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "twist_admin_id" bigint NOT NULL REFERENCES public.twist_admin (id) ON DELETE CASCADE,
    "environment" twist_environment NOT NULL DEFAULT 'personal' ::twist_environment,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "name" text NOT NULL,
    "description" text,
    "version" text NOT NULL,
    "permissions" jsonb,
    "options" jsonb,
    "is_source" boolean NOT NULL DEFAULT false,
    "shared" boolean NOT NULL DEFAULT false,
    "key_option" text,
    "logo_url" text,
    "logo_url_dark" text,
    "execution_limit" integer
);

CREATE INDEX idx_twist_admin_id ON "public"."twist" ("twist_admin_id");
CREATE INDEX idx_twist_environment ON "public"."twist" ("environment");

-- Ensure each twist_admin can only have one twist per environment
CREATE UNIQUE INDEX twist_admin_environment_unique ON "public"."twist" ("twist_admin_id", "environment");

CREATE TRIGGER set_twist_updated_at
    BEFORE INSERT OR UPDATE ON "public"."twist"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_twist_created_at
    BEFORE INSERT ON "public"."twist"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

-- Function to get twists accessible to a user for a given priority
