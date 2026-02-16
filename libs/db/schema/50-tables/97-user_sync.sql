CREATE TABLE IF NOT EXISTS user_sync (
  user_id uuid NOT NULL REFERENCES public."user"(id) ON DELETE CASCADE,
  entity text NOT NULL,
  last_update_at timestamptz NOT NULL,
  last_sync_at timestamptz NOT NULL DEFAULT '1970-01-01'::timestamptz,
  PRIMARY KEY (user_id, entity)
);

-- Index for querying pending updates
CREATE INDEX IF NOT EXISTS idx_user_sync_pending ON user_sync (user_id)
  WHERE last_update_at > last_sync_at;
