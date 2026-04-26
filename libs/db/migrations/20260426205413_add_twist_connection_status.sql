-- Modify "twist_instance_connection" table
ALTER TABLE "public"."twist_instance_connection" ADD COLUMN "needs_reauth_at" timestamptz NULL, ADD COLUMN "initial_sync_started_at" timestamptz NULL, ADD COLUMN "initial_sync_completed_at" timestamptz NULL;
-- Create trigger "user_sync_twist_instance_connection_update"
CREATE TRIGGER "user_sync_twist_instance_connection_update" AFTER UPDATE ON "public"."twist_instance_connection" REFERENCING NEW TABLE AS "new_table" FOR EACH STATEMENT EXECUTE FUNCTION "public"."sync_user_for_twist_instance_connection"();
-- Modify "sync_user_for_twist_instance_connection" function
CREATE OR REPLACE FUNCTION "public"."sync_user_for_twist_instance_connection" () RETURNS trigger LANGUAGE plpgsql SET "search_path" = public AS $$
DECLARE
    v_max_at timestamptz;
    v_user_id uuid;
BEGIN
    -- Use the most recent lifecycle stamp on each row -- this matches the
    -- `updated_at` projected by the user.twist_connection view so client
    -- incremental cursors line up.
    SELECT
        MAX(GREATEST(
            connected_at,
            needs_reauth_at,
            initial_sync_started_at,
            initial_sync_completed_at
        ))
    INTO v_max_at
    FROM
        new_table;
    -- Fall back to now() for DELETE (transition table values are deleted rows).
    IF v_max_at IS NULL THEN
        v_max_at := now();
    END IF;
    -- Notify each affected user directly. Bump both `twist_instance` (legacy
    -- consumer; user.twist surfaces user_connected) and `twist_connection`
    -- (new entity for needs_reauth / initial_syncing signals).
    FOR v_user_id IN SELECT DISTINCT
        user_id
    FROM
        new_table
    ORDER BY
        user_id LOOP
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'twist_instance', v_max_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
            INSERT INTO user_sync (user_id, entity, last_update_at)
                VALUES (v_user_id, 'twist_connection', v_max_at)
            ON CONFLICT (user_id, entity)
                DO UPDATE SET
                    last_update_at = GREATEST (user_sync.last_update_at, EXCLUDED.last_update_at);
        END LOOP;
    RETURN NULL;
END;
$$;
-- Create "twist_connection" view
CREATE VIEW "user"."twist_connection" (
  "user_id",
  "twist_instance_id",
  "provider",
  "actor_id",
  "connected_at",
  "needs_reauth_at",
  "initial_sync_started_at",
  "initial_sync_completed_at",
  "needs_reauth",
  "initial_syncing",
  "updated_at"
) AS SELECT user_id,
    twist_instance_id,
    provider,
    actor_id,
    connected_at,
    needs_reauth_at,
    initial_sync_started_at,
    initial_sync_completed_at,
    needs_reauth_at IS NOT NULL AS needs_reauth,
    initial_sync_started_at IS NOT NULL AND initial_sync_completed_at IS NULL AS initial_syncing,
    GREATEST(connected_at, needs_reauth_at, initial_sync_started_at, initial_sync_completed_at) AS updated_at
   FROM public.twist_instance_connection tic;
