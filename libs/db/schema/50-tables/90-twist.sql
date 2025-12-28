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
    "twist_package_id" uuid NOT NULL DEFAULT gen_random_uuid (),
    "user_id" uuid REFERENCES auth.users ON DELETE CASCADE,
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

ALTER TABLE "public"."twist_admin" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_twist_admin_updated_at
    BEFORE UPDATE ON "public"."twist_admin"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

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
    "permissions" jsonb
);

CREATE INDEX idx_twist_admin_id ON "public"."twist" ("twist_admin_id");
CREATE INDEX idx_twist_environment ON "public"."twist" ("environment");

ALTER TABLE "public"."twist" ENABLE ROW LEVEL SECURITY;

CREATE UNIQUE INDEX twist_name_unique_public_review ON public.twist (name)
WHERE
    environment IN ('public', 'review');

CREATE TRIGGER set_twist_updated_at
    BEFORE UPDATE ON "public"."twist"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

-- Function to get twists accessible to a user for a given priority
