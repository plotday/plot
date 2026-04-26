CREATE TABLE "public"."twist_instance_connection" (
    "twist_instance_id" uuid NOT NULL REFERENCES public.twist_instance ON DELETE CASCADE,
    "user_id" uuid NOT NULL REFERENCES public."user" ON DELETE CASCADE,
    "provider" text NOT NULL,
    "actor_id" uuid NOT NULL,
    "connected_at" timestamptz NOT NULL DEFAULT now(),
    -- Set when a permanent OAuth refresh failure (or equivalent) means the user
    -- must re-authenticate this connection. NULL = OK. Cleared on successful re-auth.
    "needs_reauth_at" timestamptz NULL,
    -- Initial bulk sync lifecycle for this connection. The derived
    -- `initial_syncing` boolean exposed in user.twist_connection is
    -- (initial_sync_started_at IS NOT NULL AND initial_sync_completed_at IS NULL).
    "initial_sync_started_at" timestamptz NULL,
    "initial_sync_completed_at" timestamptz NULL,
    PRIMARY KEY ("twist_instance_id", "user_id", "provider")
);

CREATE INDEX idx_twist_instance_connection_user_id ON twist_instance_connection (user_id);
CREATE INDEX idx_twist_instance_connection_instance ON twist_instance_connection (twist_instance_id);
