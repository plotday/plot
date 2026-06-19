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
    -- How many times the stuck-sync watchdog has re-dispatched this
    -- connection's initial sync without it completing. Bounds recovery: after
    -- a few failed cycles the watchdog stops re-running a sync that never
    -- finishes (e.g. a connector whose backfill keeps throwing) and instead
    -- flags `needs_reauth_at`, so the user sees "Reconnect" rather than an
    -- eternal "Syncing" spinner. Reset to 0 on successful completion
    -- (channelSyncCompleted) and on re-auth (the needs_reauth clear path).
    "initial_sync_attempts" integer NOT NULL DEFAULT 0,
    -- Set by the runtime when a queued connector callback fails with an
    -- auth-related error, or after re-auth. The next `onChannelEnabled`
    -- dispatch (from any path: user toggle, refresh, recovery) reads this
    -- and automatically passes `recovering: true` in the SyncContext, then
    -- clears the flag. Connectors do not need to read or write this.
    "recovery_pending" boolean NOT NULL DEFAULT false,
    "seq" xid8 NOT NULL DEFAULT pg_current_xact_id(),
    PRIMARY KEY ("twist_instance_id", "user_id", "provider")
);

CREATE INDEX idx_twist_instance_connection_user_id ON twist_instance_connection (user_id);
CREATE INDEX idx_twist_instance_connection_instance ON twist_instance_connection (twist_instance_id);
CREATE INDEX idx_twist_instance_connection_seq ON twist_instance_connection (seq);

-- twist_instance_connection has no updated_at column — bump seq directly
-- on UPDATE so sync queries see the change.
CREATE TRIGGER set_twist_instance_connection_seq
    BEFORE UPDATE ON "public"."twist_instance_connection"
    FOR EACH ROW
    EXECUTE FUNCTION update_seq ();
