-- All twists start in the 'personal' environment, which is the development environment.
-- They can be promoted to 'private' for private use, then to 'review'.
-- Only Plot can promote from 'review' to 'public'.
CREATE TYPE twist_environment AS ENUM (
    'personal',
    'private',
    'review',
    'public'
);

CREATE TABLE "public"."twist" (
    "id" bigint NOT NULL GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "twist_package_id" uuid NOT NULL,
    "publisher_id" bigint REFERENCES public.publisher (id) ON DELETE CASCADE,
    "user_id" uuid REFERENCES public."user" ("id") ON DELETE CASCADE,
    "environment" twist_environment NOT NULL DEFAULT 'personal' ::twist_environment,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "name" text NOT NULL,
    -- At-mention / attribution label. Defaults to `name` when not supplied
    -- by the twist's package.json. Distinct from `name` (settings/marketplace
    -- label) so a twist can read as "@Plot" in the editor while showing as
    -- "Plot AI Assistant" in settings.
    "handle" text NOT NULL,
    -- When non-null, this twist appears as a choice in the new-thread
    -- connection picker with this label (e.g. "Plot AI chat"). When null
    -- the twist is not offered as a chat target.
    "thread_type" text,
    "description" text,
    -- Connector classification used to group connectors in the UI (e.g. the
    -- onboarding "Connect your tools" step). Known values: 'messaging',
    -- 'calendar'. Open-ended for future categories (e.g. 'tasks',
    -- 'read_later'); null/unknown is treated as a generic app. Set at deploy
    -- time from the connector's package.json `category` field.
    "category" text,
    "version" text NOT NULL,
    "permissions" jsonb,
    "options_schema" jsonb,
    "is_source" boolean NOT NULL DEFAULT false,
    "shared" boolean NOT NULL DEFAULT false,
    "key_option" text,
    -- Add-on connector flag. Set to true at deploy time for connectors with
    -- real per-connection cost (e.g. Unipile-backed LinkedIn / Instagram /
    -- WhatsApp). Surfaced to users as paid "connection add-ons": enabling one
    -- requires a purchased add-on credit (premium_connection_addons) AND
    -- consumes a regular connection slot. Not available on Free.
    "premium" boolean NOT NULL DEFAULT false,
    "logo_url" text,
    "logo_url_dark" text,
    "execution_limit" integer,
    "multiple_instances" boolean NOT NULL DEFAULT false,
    "reaction_capabilities" jsonb,
    "auto_approve" boolean NOT NULL DEFAULT FALSE,
    -- Bumped on every UPDATE by `update_seq_and_updated_at` so that changes
    -- to `permissions` (link_types, defaults) and other twist-level metadata
    -- propagate through `user.twist` to clients via the seq-cursor sync.
    -- Without this, redeploys that rewrite `permissions` are invisible to
    -- existing client caches.
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    CONSTRAINT "twist_owner_check" CHECK (
        (environment = 'personal' AND user_id IS NOT NULL AND publisher_id IS NULL)
        OR
        (environment <> 'personal' AND publisher_id IS NOT NULL AND user_id IS NULL)
    )
);

CREATE INDEX idx_twist_publisher_id ON "public"."twist" ("publisher_id") WHERE publisher_id IS NOT NULL;
CREATE INDEX idx_twist_user_id ON "public"."twist" ("user_id") WHERE user_id IS NOT NULL;
CREATE INDEX idx_twist_environment ON "public"."twist" ("environment");
CREATE INDEX idx_twist_package_id ON "public"."twist" ("twist_package_id");

CREATE INDEX idx_twist_seq ON "public"."twist" ("seq");

-- Personal twists: one per (package, user). Each user has their own personal deployment of a package.
CREATE UNIQUE INDEX twist_personal_package_user_unique ON "public"."twist" ("twist_package_id", "user_id")
    WHERE environment = 'personal';

-- Non-personal twists: one per (package, environment). All non-personal rows for a given package
-- must share the same publisher_id (enforced by the enforce_twist_package_publisher_consistency trigger).
CREATE UNIQUE INDEX twist_non_personal_package_environment_unique ON "public"."twist" ("twist_package_id", "environment")
    WHERE environment <> 'personal';

CREATE TRIGGER set_twist_updated_at
    BEFORE INSERT OR UPDATE ON "public"."twist"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq_and_updated_at ();

CREATE TRIGGER set_twist_created_at
    BEFORE INSERT ON "public"."twist"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

-- Enforce that all non-personal rows for the same twist_package_id share the same publisher_id.
-- A user attempting to deploy a package that's already "claimed" by another publisher will be
-- rejected here; the API-layer topic check determines whether the user can claim an unclaimed package.
CREATE OR REPLACE FUNCTION public.enforce_twist_package_publisher_consistency ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_existing_publisher_id bigint;
BEGIN
    IF NEW.environment = 'personal' THEN
        RETURN NEW;
    END IF;

    SELECT publisher_id INTO v_existing_publisher_id
    FROM twist
    WHERE twist_package_id = NEW.twist_package_id
      AND environment <> 'personal'
      AND id <> COALESCE(NEW.id, -1)
    LIMIT 1;

    IF v_existing_publisher_id IS NOT NULL AND v_existing_publisher_id <> NEW.publisher_id THEN
        RAISE EXCEPTION 'twist_package_id % is already owned by publisher %, cannot assign to publisher %',
            NEW.twist_package_id, v_existing_publisher_id, NEW.publisher_id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER enforce_twist_package_publisher_consistency
    BEFORE INSERT OR UPDATE OF twist_package_id, publisher_id, environment ON "public"."twist"
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_twist_package_publisher_consistency ();
