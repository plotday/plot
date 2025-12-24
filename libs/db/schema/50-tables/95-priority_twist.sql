CREATE TABLE "public"."priority_twist" (
    "id" uuid PRIMARY KEY DEFAULT gen_random_uuid_v7 () NOT NULL,
    "priority_id" uuid NOT NULL REFERENCES public.priority ON DELETE CASCADE,
    "twist_id" uuid NOT NULL,
    "twist_environment" twist_environment NOT NULL,
    "owner_id" uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    "name" text NOT NULL,
    "config" jsonb NOT NULL DEFAULT '{}' ::jsonb,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    FOREIGN KEY (twist_id, twist_environment) REFERENCES public.twist (id, environment) ON DELETE CASCADE
);

CREATE INDEX idx_twist_priority_id ON "public"."priority_twist" ("priority_id");

CREATE INDEX idx_priority_twist_twist ON "public"."priority_twist" ("twist_id", "twist_environment");

ALTER TABLE "public"."priority_twist" ENABLE ROW LEVEL SECURITY;

CREATE TRIGGER set_twist_updated_at
    BEFORE UPDATE ON "public"."priority_twist"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

-- Function to set owner_id to current user on INSERT
CREATE OR REPLACE FUNCTION set_priority_twist_owner_id ()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.owner_id := auth.uid ();
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

CREATE TRIGGER notify_priority_twist_update
    AFTER INSERT OR UPDATE ON "public"."priority_twist"
    FOR EACH ROW
    EXECUTE FUNCTION notify_internal_api_for_priority_twist ();

