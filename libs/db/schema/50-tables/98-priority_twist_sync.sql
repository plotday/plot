CREATE TABLE IF NOT EXISTS priority_twist_sync (
  priority_twist_id uuid NOT NULL REFERENCES priority_twist(id) ON DELETE CASCADE,
  entity text NOT NULL,
  operation sync_operation NOT NULL,
  last_update_at timestamptz NOT NULL,
  last_sync_at timestamptz NOT NULL DEFAULT '1970-01-01'::timestamptz,
  PRIMARY KEY (priority_twist_id, entity, operation)
);

-- Index for querying pending updates
CREATE INDEX IF NOT EXISTS idx_priority_twist_sync_pending ON priority_twist_sync (priority_twist_id)
  WHERE last_update_at > last_sync_at;
