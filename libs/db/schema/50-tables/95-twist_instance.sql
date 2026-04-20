CREATE TABLE "public"."twist_instance" (
    -- While we could use a bigint here, we use uuid so this can also be used as an actor_id
    "id" uuid PRIMARY KEY DEFAULT uuidv7 () NOT NULL,
    "twist_id" bigint NOT NULL REFERENCES public.twist (id) ON DELETE CASCADE,
    "owner_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    -- Optional team that owns this twist for billing/quota purposes.
    -- NULL = personal (counts against the owner user's plan).
    "team_id" bigint REFERENCES public.team (id) ON DELETE SET NULL,
    "name" text NOT NULL,
    -- For source (connection) instances, a per-connection disambiguator shown as
    -- the subtitle in the Connections list and composed into the actor display
    -- name (`ConnectorName (account_label)`). Populated per-provider at auth
    -- time; user-editable in EditSource. NULL for non-source twists.
    "account_label" text,
    "options" jsonb NOT NULL DEFAULT '{}' ::jsonb,
    -- true while the user is configuring the twist (pre-activation). Drafts
    -- are excluded from most views and are hard-deleted if abandoned.
    "draft" boolean NOT NULL DEFAULT FALSE,
    "created_at" timestamp with time zone NOT NULL DEFAULT now(),
    "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
    "archived_at" timestamp with time zone,
    "suspended_at" timestamp with time zone
);

CREATE INDEX idx_twist_instance_owner_id ON "public"."twist_instance" ("owner_id");

CREATE INDEX idx_twist_instance_team_id ON "public"."twist_instance" ("team_id") WHERE team_id IS NOT NULL;

CREATE INDEX idx_twist_instance_twist_id ON "public"."twist_instance" ("twist_id");

CREATE TRIGGER set_twist_instance_updated_at
    BEFORE INSERT OR UPDATE ON "public"."twist_instance"
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at ();

CREATE TRIGGER set_twist_instance_created_at
    BEFORE INSERT ON "public"."twist_instance"
    FOR EACH ROW
    EXECUTE FUNCTION set_created_at ();

-- Function to set owner_id to current user on INSERT
-- Uses COALESCE to support setting owner_id
CREATE OR REPLACE FUNCTION set_twist_instance_owner_id ()
    RETURNS TRIGGER
    AS $$
BEGIN
    IF NEW.owner_id IS NULL THEN
        RAISE EXCEPTION 'owner_id must be provided';
    END IF;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER set_twist_instance_owner_id
    BEFORE INSERT ON "public"."twist_instance"
    FOR EACH ROW
    EXECUTE FUNCTION set_twist_instance_owner_id ();

-- Function to prevent changes to immutable fields (twist_id, owner_id)
CREATE OR REPLACE FUNCTION public.prevent_twist_instance_immutable_changes ()
    RETURNS TRIGGER
    LANGUAGE plpgsql
    AS $function$
BEGIN
    -- Prevent changing twist_id
    IF OLD.twist_id IS DISTINCT FROM NEW.twist_id THEN
        RAISE EXCEPTION 'Cannot change twist_id of an existing twist_instance';
    END IF;
    -- Prevent changing owner_id
    IF OLD.owner_id IS DISTINCT FROM NEW.owner_id THEN
        RAISE EXCEPTION 'Cannot change owner_id of an existing twist_instance';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER prevent_twist_instance_immutable_changes
    BEFORE UPDATE ON "public"."twist_instance"
    FOR EACH ROW
    EXECUTE FUNCTION prevent_twist_instance_immutable_changes ();
