-- User-accessible per-connection status for a twist instance.
--
-- Surfaces re-auth and initial-sync signals to the Flutter app via the
-- existing user-sync mechanism. One row per (twist_instance, user, provider)
-- pairing where the row's user_id matches the calling user. Row-level scoping
-- is achieved by exposing twist_instance_connection.user_id directly --
-- callers filter `WHERE user_id = <auth user>` like the other user.* views
-- (see user.twist, user.channel).
CREATE OR REPLACE VIEW "user"."twist_connection" --
AS
SELECT
    tic.user_id,
    tic.twist_instance_id,
    tic.provider,
    tic.actor_id,
    tic.connected_at,
    tic.needs_reauth_at,
    tic.initial_sync_started_at,
    tic.initial_sync_completed_at,
    (tic.needs_reauth_at IS NOT NULL) AS needs_reauth,
    (
        tic.initial_sync_started_at IS NOT NULL
        AND tic.initial_sync_completed_at IS NULL
    ) AS initial_syncing,
    -- Composite "freshness" timestamp the client uses for incremental sync.
    -- Picks the most recent of the lifecycle stamps.
    GREATEST(
        tic.connected_at,
        tic.needs_reauth_at,
        tic.initial_sync_started_at,
        tic.initial_sync_completed_at
    ) AS updated_at,
    tic.seq
FROM
    twist_instance_connection tic;
