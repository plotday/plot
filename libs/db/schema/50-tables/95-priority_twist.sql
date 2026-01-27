CREATE TABLE "public"."priority_twist" (
    -- While we could use a bigint here, we use uuid so this can also be used as an actor_id
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "twist_id" bigint NOT NULL REFERENCES public.twist (id) ON DELETE CASCADE,
    "owner_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "name" text NOT NULL,
    "config" jsonb NOT NULL DEFAULT '{}' ::jsonb,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone
);

CREATE INDEX idx_twist_priority_id ON "public"."priority_twist" ("priority_id");

CREATE INDEX idx_priority_twist_twist ON "public"."priority_twist" ("twist_id");

ALTER TABLE "public"."priority_twist" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_priority_twist_updated_at
    BEFORE INSERT OR UPDATE ON "public"."priority_twist"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_priority_twist_created_at
    BEFORE INSERT ON "public"."priority_twist"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

-- Function to set owner_id to current user on INSERT
-- Uses COALESCE to support both authenticated users and service_role operations
-- When auth.uid() is available (authenticated users), use it
-- When auth.uid() is NULL (service_role/admin), use the explicitly provided owner_id
CREATE OR REPLACE FUNCTION set_priority_twist_owner_id ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.owner_id := COALESCE(auth.uid (), NEW.owner_id);
    RETURN NEW;
END;
$$
LANGUAGE plpgsql
SECURITY DEFINER;

CREATE TRIGGER set_priority_twist_owner_id
    BEFORE INSERT ON "public"."priority_twist"
    FOR EACH ROW
    EXECUTE FUNCTION set_priority_twist_owner_id ();

-- Function to prevent changes to immutable fields (twist_id, owner_id)
CREATE OR REPLACE FUNCTION public.prevent_priority_twist_immutable_changes ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $function$
BEGIN
    -- Prevent changing twist_id
    IF OLD.twist_id IS DISTINCT FROM NEW.twist_id THEN
        RAISE EXCEPTION 'Cannot change twist_id of an existing priority_twist';
    END IF;
    -- Prevent changing owner_id
    IF OLD.owner_id IS DISTINCT FROM NEW.owner_id THEN
        RAISE EXCEPTION 'Cannot change owner_id of an existing priority_twist';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER prevent_priority_twist_immutable_changes
    BEFORE UPDATE ON "public"."priority_twist"
    FOR EACH ROW
    EXECUTE FUNCTION prevent_priority_twist_immutable_changes ();

-- Trigger functions cannot be called via RPC, but REVOKE for defense-in-depth
REVOKE EXECUTE ON FUNCTION public.set_priority_twist_owner_id () FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.prevent_priority_twist_immutable_changes () FROM PUBLIC;

